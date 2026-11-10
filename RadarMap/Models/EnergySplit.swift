//
//  EnergySplit.swift
//  RadarMap
//
//  Сколько километров на электричестве, сколько на бензине и во что это
//  обошлось (план 21.10, 21.2) — по дням и по реальным поездкам.
//
//  Почему не постоянная доля, как было до 21.10: у гибрида с розеткой доли
//  нет. День 40 км по городу — всё на электричестве, поездка в Самарканд —
//  в основном бензин. Цифру «доля пробега на электричестве», которую нужно
//  было угадать, никто не знал, и стоимость выходила неправдоподобной.
//
//  Как считаем гибрид с розеткой:
//   1. Заряд дня — реальный запас в км; полный после зарядки по графику
//      (каждую ночь — каждый день, через день — раз в два дня…).
//   2. Поездки дня по порядку тратят заряд: пока он есть — на электричестве,
//      остаток — на бензине в гибридном режиме.
//   3. Трасса (быстрее 80 км/ч по профилю скорости поездки) тратит заряд в
//      1,3 раза быстрее — запас на ней честно кончается раньше. Профиля нет
//      (трек старше недели) — трассу не учитываем и говорим об этом.
//   4. Чего не знаем — не выдумываем: нет цены — нет суммы, но километры и
//      кВт·ч по видам энергии видны всё равно.
//
//  Поездки, чьи записи уже вычищены, считаются по дневному агрегату — км
//  дня хранятся всегда (правило 16): остаток дня становится одной «поездкой»
//  в начале дня. Пассажирские поездки не записываются вовсе.
//
//  Всё здесь — чистые nonisolated-функции (EnergySplitTests). Ничего из
//  этого не уходит с телефона.
//

import Foundation

nonisolated enum EnergySplit {

    // MARK: - Модель машины

    /// Как машина тратит энергию — выведено из профиля и типа один раз.
    struct Model: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// Один вид энергии: бензин, гибрид без розетки.
            case single(Fuel)
            /// Электромобиль: всё на электричестве; запас — для пометки
            /// «нужна зарядка в пути».
            case electric(rangeKm: Double?)
            /// Постоянная доля второго вида: метан/пропан + бензин; гибрид с
            /// розеткой, который почти не заряжают (доля — на электричестве).
            case mixed(primary: Fuel, second: Fuel, secondShare: Double)
            /// Гибрид с розеткой по дням: заряд дня тратится первым.
            case plugIn(rangeKm: Double, everyDays: Int)
            /// Гибрид с розеткой без запаса хода: разложить нельзя, только км.
            case needsRange
        }

        var kind: Kind
        /// Единиц на 100 км по виду энергии; нет ключа — расход неизвестен.
        /// Электричество — по городу, трасса умножается на коэффициент.
        var per100: [Fuel: Double] = [:]
        /// Сумов за единицу; электричество — по месту зарядки. Нет ключа — нет цены.
        var price: [Fuel: Double] = [:]
        /// Расход электричества — типичный, а не из ёмкости или с панели.
        var kWhIsEstimate = false

        /// Тратит ли машина заряд батареи (от него зависит трасса и запас).
        var usesBattery: Bool {
            switch kind {
            case .electric, .plugIn: return true
            case .mixed(_, let second, _): return second == .electricity
            case .single, .needsRange: return false
            }
        }

        /// Реальный запас, км, если он участвует в расчёте.
        var rangeKm: Double? {
            switch kind {
            case .electric(let range): return range
            case .plugIn(let range, _): return range
            default: return nil
            }
        }
    }

    static func model(profile: FuelProfile, energy: VehicleEnergy) -> Model {
        var per100: [Fuel: Double] = [:]
        var price: [Fuel: Double] = [:]
        for fuel in [Fuel.petrol, .methane, .propane] {
            let rate = profile.rate(fuel)
            if rate.per100Km > 0 { per100[fuel] = rate.per100Km }
            if rate.price > 0 { price[fuel] = rate.price }
        }
        let kWh = profile.kWhPer100
        per100[.electricity] = kWh.value
        if let electricity = profile.electricityPrice { price[.electricity] = electricity }

        let gasShare = min(0.9, max(0, profile.secondShare))
        let kind: Model.Kind
        switch energy {
        case .fuel, .hev: kind = .single(.petrol)
        case .cng: kind = .mixed(primary: .methane, second: .petrol, secondShare: gasShare)
        case .lpg: kind = .mixed(primary: .propane, second: .petrol, secondShare: gasShare)
        case .electric: kind = .electric(rangeKm: profile.realRangeKm)
        case .hybrid:
            let schedule = profile.chargeSchedule ?? .nightly
            let share = min(1, max(0, profile.secondShare))
            if let every = schedule.everyDays, let range = profile.realRangeKm {
                kind = .plugIn(rangeKm: range, everyDays: every)
            } else if schedule == .rarely || share > 0 {
                // «Почти никогда не заряжаю» — постоянная доля; так же — гибрид,
                // настроенный до 21.10 одной долей, пока запас не указан.
                kind = .mixed(primary: .petrol, second: .electricity, secondShare: share)
            } else {
                kind = .needsRange
            }
        }
        return Model(kind: kind, per100: per100, price: price,
                     kWhIsEstimate: energy.plugs && kWh.isEstimate)
    }

    // MARK: - Вход: дни и поездки

    struct Trip: Equatable, Sendable {
        /// id записи поездки; nil — часть дня, чья запись уже вычищена.
        var id: Double?
        var start: Date
        var meters: Double
        /// Метров быстрее 80 км/ч; nil — профиля скорости нет.
        var highwayMeters: Double?
        /// Рейс «Работаю водителем» — для строки смены.
        var work = false
    }

    struct Day: Equatable, Sendable {
        /// Начало дня — ключ дневного агрегата (TripDay.day).
        var day: Date
        var trips: [Trip]
    }

    /// Дни для расчёта: записи поездок там, где они есть, остаток дня — из
    /// дневного агрегата. Запись относится к строке дня, в чьи сутки попал её
    /// старт (по интервалу, а не по ключу: при смене часового пояса полночь
    /// строки и полночь записи разъехались бы, и день посчитался бы дважды).
    static func days(tripDays: [TripDay], records: [TripRecord],
                     calendar: Calendar = .current) -> [Day] {
        let rows = tripDays.sorted { $0.day < $1.day }
        var matched = [[TripRecord]](repeating: [], count: rows.count)
        var loose: [Date: [TripRecord]] = [:]
        for record in records {
            if let index = rowIndex(for: record.startedAt, in: rows) {
                matched[index].append(record)
            } else {
                loose[calendar.startOfDay(for: record.startedAt), default: []].append(record)
            }
        }
        var result: [Day] = []
        for (index, row) in rows.enumerated() {
            let own = matched[index].sorted { $0.startedAt < $1.startedAt }
            var trips = own.map(trip(from:))
            let remainder = row.distanceMeters - own.reduce(0) { $0 + $1.distanceMeters }
            if remainder > AppConfig.energyRemainderMinMeters {
                // Вычищенные записи — самые старые, то есть утренние: в начало.
                trips.insert(Trip(id: nil, start: row.day, meters: remainder), at: 0)
            }
            if !trips.isEmpty { result.append(Day(day: row.day, trips: trips)) }
        }
        for (day, own) in loose {
            result.append(Day(day: day, trips: own.sorted { $0.startedAt < $1.startedAt }.map(trip(from:))))
        }
        return result.sorted { $0.day < $1.day }
    }

    /// Строка дня, в чьи сутки попал момент; nil — такой строки нет.
    private static func rowIndex(for date: Date, in rows: [TripDay]) -> Int? {
        var low = 0, high = rows.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if rows[mid].day <= date { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        // Сутки с запасом в час — на переход часов, которого в Узбекистане
        // нет, но у путешественника бывает.
        guard let found, date.timeIntervalSince(rows[found].day) < 86_400 + 3_600 else { return nil }
        return found
    }

    static func trip(from record: TripRecord) -> Trip {
        Trip(id: record.id, start: record.startedAt, meters: record.distanceMeters,
             highwayMeters: highwayMeters(of: record), work: record.work == true)
    }

    /// Сколько метров поездки шло быстрее 80 км/ч — по профилю скорости
    /// упрощённого трека, в доле от длины записи. nil — трека нет (их
    /// вырезают через неделю).
    static func highwayMeters(of record: TripRecord) -> Double? {
        guard let track = record.track, track.count >= 6 else { return nil }
        var total = 0.0
        var fast = 0.0
        var index = 0
        while index + 5 < track.count {
            let step = GeoMath.fastDistance(track[index], track[index + 1], track[index + 3], track[index + 4])
            // Скорость отрезка — средняя его концов; отрицательная — «не знаем».
            let speed = (max(0, track[index + 2]) + max(0, track[index + 5])) / 2
            total += step
            if speed > AppConfig.energyHighwayKmh { fast += step }
            index += 3
        }
        guard total > 0 else { return nil }
        return record.distanceMeters * fast / total
    }

    // MARK: - Выход

    /// Сколько энергии и денег ушло на путь.
    struct Use: Equatable, Sendable {
        /// Метров по виду энергии.
        var meters: [Fuel: Double] = [:]
        /// Единиц (л, м³, кВт·ч) — только там, где расход известен.
        var amount: [Fuel: Double] = [:]
        /// Сумов — по видам энергии, у которых известны и расход, и цена.
        var money: Double = 0
        /// Ехали на этом, но расход неизвестен — сумма неполная.
        var missingConsumption: Set<Fuel> = []
        /// Ехали на этом, но цены нет — сумма неполная.
        var missingPrice: Set<Fuel> = []
        /// Метров, которые не разложить: гибрид с розеткой без запаса хода.
        var unsplitMeters: Double = 0
        /// Метров по трассе, учтённых в заряде.
        var highwayMeters: Double = 0
        /// Метров без профиля скорости, когда от трассы зависел заряд.
        var noSpeedProfileMeters: Double = 0
        /// Поездок длиннее реального запаса (электромобиль): нужна зарядка в пути.
        var beyondRangeTrips = 0

        func meters(_ fuel: Fuel) -> Double { meters[fuel] ?? 0 }
        var totalMeters: Double { meters.values.reduce(0, +) + unsplitMeters }

        /// Сумма в сумах; nil — чего-то не хватает (расхода или цены).
        var cost: Double? {
            guard totalMeters > 0, unsplitMeters == 0,
                  missingConsumption.isEmpty, missingPrice.isEmpty else { return nil }
            return money
        }

        /// Доля пути на электричестве; nil — пути нет или он не разложен.
        var electricShare: Double? {
            guard totalMeters > 0, unsplitMeters == 0 else { return nil }
            return meters(.electricity) / totalMeters
        }

        static func + (a: Use, b: Use) -> Use {
            var sum = a
            sum.meters.merge(b.meters, uniquingKeysWith: +)
            sum.amount.merge(b.amount, uniquingKeysWith: +)
            sum.money += b.money
            sum.missingConsumption.formUnion(b.missingConsumption)
            sum.missingPrice.formUnion(b.missingPrice)
            sum.unsplitMeters += b.unsplitMeters
            sum.highwayMeters += b.highwayMeters
            sum.noSpeedProfileMeters += b.noSpeedProfileMeters
            sum.beyondRangeTrips += b.beyondRangeTrips
            return sum
        }

        /// Путь на одном виде энергии; `drain` — во сколько раз быстрее
        /// обычного тратится единица на км (трасса для батареи).
        fileprivate mutating func add(_ fuel: Fuel, meters distance: Double, drain: Double = 1, model: Model) {
            guard distance > 0 else { return }
            meters[fuel, default: 0] += distance
            guard let per100 = model.per100[fuel], per100 > 0 else {
                missingConsumption.insert(fuel)
                return
            }
            let units = distance / 100_000 * per100 * drain
            amount[fuel, default: 0] += units
            if let price = model.price[fuel], price > 0 {
                money += units * price
            } else {
                missingPrice.insert(fuel)
            }
        }
    }

    /// Поездка в итогах: когда, рейс ли смены и что потратила.
    struct Entry: Equatable, Sendable {
        var start: Date
        var work: Bool
        var use: Use
    }

    /// Всё посчитанное разом: по поездкам и по дням.
    struct Ledger: Equatable, Sendable {
        var model: Model
        var trips: [Double: Entry] = [:]
        var days: [Date: Use] = [:]

        /// Сумма по дням окна — дни выбирает `TripDayBook.days(_:in:)`.
        func use(of tripDays: [TripDay]) -> Use {
            tripDays.reduce(Use()) { $0 + (days[$1.day] ?? Use()) }
        }

        /// Поездки, начавшиеся в [from, through]; `workOnly` — только рейсы смены.
        func use(from: Date, through: Date, workOnly: Bool) -> Use {
            trips.values.reduce(Use()) { sum, entry in
                guard entry.start >= from, entry.start <= through, !workOnly || entry.work else { return sum }
                return sum + entry.use
            }
        }

        /// Дорога на работу (или домой) за 30 дней: поездки, путь и деньги.
        /// Поездка, которой в расчёте нет (он знает только записи истории, а
        /// журнал дороги держит 45 дней), — по цене километра посчитанных
        /// поездок этой же дороги: без неё сумма молча занижалась (разбор
        /// 10.11). nil — ни одной посчитанной поездки или нет цены.
        func commuteMonth(_ commute: [Commute.Trip], now: Date) -> CommuteMonth? {
            let since = now.addingTimeInterval(-30 * 86_400)
            let recent = commute.filter { $0.departure >= since && $0.departure <= now }
            var known = Use()
            var knownMeters = 0.0
            for trip in recent {
                guard let entry = trips[trip.id] else { continue }
                known = known + entry.use
                knownMeters += trip.distanceMeters
            }
            guard let cost = known.cost, knownMeters > 0 else { return nil }
            let meters = recent.reduce(0) { $0 + $1.distanceMeters }
            return CommuteMonth(cost: FuelCost.rounded(cost * meters / knownMeters),
                                trips: recent.count, meters: meters)
        }
    }

    /// Дорога за 30 дней — для строки «22 поездки, 270 км · топливо ≈ …».
    struct CommuteMonth: Equatable, Sendable {
        let cost: Double
        let trips: Int
        let meters: Double
    }

    // MARK: - Расчёт

    /// Разложить дни на электричество и топливо. Дни — по порядку, поездки
    /// дня — по старту; график зарядки отсчитывается от последней зарядки:
    /// «через день» после недели стоянки — снова полный заряд, как в жизни.
    static func split(_ days: [Day], model: Model, calendar: Calendar = .current) -> Ledger {
        var ledger = Ledger(model: model)
        var budget = 0.0
        var lastCharge: Date?
        for day in days.sorted(by: { $0.day < $1.day }) {
            if case .plugIn(let range, let every) = model.kind {
                let elapsed = lastCharge.map { calendar.dateComponents([.day], from: $0, to: day.day).day ?? 0 }
                if elapsed.map({ $0 >= every }) ?? true {
                    budget = range * 1_000
                    lastCharge = day.day
                }
            }
            var total = Use()
            for trip in day.trips.sorted(by: { $0.start < $1.start }) {
                let use = self.use(trip, model: model, budget: &budget)
                if let id = trip.id { ledger.trips[id] = Entry(start: trip.start, work: trip.work, use: use) }
                total = total + use
            }
            ledger.days[day.day] = total
        }
        return ledger
    }

    /// Одна поездка; `budget` — остаток заряда дня в «городских» метрах.
    static func use(_ trip: Trip, model: Model, budget: inout Double) -> Use {
        var use = Use()
        let distance = max(0, trip.meters)
        guard distance > 0 else { return use }
        let highway = trip.highwayMeters.map { min(distance, max(0, $0)) } ?? 0
        let drain = 1 + (AppConfig.energyHighwayFactor - 1) * highway / distance

        switch model.kind {
        case .single(let fuel):
            use.add(fuel, meters: distance, model: model)
        case .mixed(let primary, let second, let share):
            use.add(primary, meters: distance * (1 - share), model: model)
            use.add(second, meters: distance * share, model: model)
        case .electric(let range):
            use.add(.electricity, meters: distance, drain: drain, model: model)
            if let range, distance * drain > range * 1_000 { use.beyondRangeTrips = 1 }
        case .plugIn:
            let electric = min(distance, max(0, budget) / drain)
            budget = max(0, budget - electric * drain)
            use.add(.electricity, meters: electric, drain: drain, model: model)
            use.add(.petrol, meters: distance - electric, model: model)
        case .needsRange:
            use.unsplitMeters = distance
        }

        switch model.kind {
        case .electric, .plugIn:
            if trip.highwayMeters == nil {
                use.noSpeedProfileMeters = distance
            } else {
                use.highwayMeters = highway
            }
        default:
            break
        }
        return use
    }

    /// Весь расчёт по истории — то, что читают экраны.
    static func ledger(tripDays: [TripDay], records: [TripRecord], profile: FuelProfile,
                       energy: VehicleEnergy, calendar: Calendar = .current) -> Ledger {
        split(days(tripDays: tripDays, records: records, calendar: calendar),
              model: model(profile: profile, energy: energy), calendar: calendar)
    }
}
