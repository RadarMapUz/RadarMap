//
//  CarPlayRouteChoiceOffer.swift
//  RadarMap
//
//  Маршрут построен на ходу (на телефоне или «Куда» в машине): выбора вариантов
//  в машине не было — читать список на скорости нельзя (NavigationFlow.carChoice).
//  До 51 он не появлялся и потом: решения принимались только на смене фазы, а
//  остановка фазу не меняет. Теперь машина предлагает выбор один раз, когда
//  стоит по-настоящему, — баннером «Есть другие варианты», а список открывается
//  только касанием. Ведение без касания не прерывается никогда.
//
//  Что считается поводом:
//    • стоянка устойчивая: `carPlayChoiceOfferStandSeconds` (90 с) не быстрее
//      порога и без сдвига по маршруту. Красный свет (обычно до минуты с
//      небольшим) и рывки пробки счёт сбрасывают или не доходят до него; пробка
//      по данным на нашем пути — отдельное «нет»;
//    • предложение не устарело: проехано меньше четверти пути и либо маршрут
//      свежий, либо проехано мало. Устаревшее не вернётся — путь только растёт;
//    • есть из чего выбирать: кроме выбранного варианта есть заметно другой, и
//      машина стоит на его линии — иначе выбор тут же сменился бы перестроением.
//
//  Один раз на набор вариантов: показанный баннер (ответ, молчание, вытеснение
//  камерой) и любой показ списка закрывают вопрос. Перестроение и объезд строят
//  один вариант, поэтому сами предложения не вызывают; новый набор из двух и
//  больше вариантов строит только водитель — это новый маршрут.
//
//  Чистая логика; CarPlayRouteChoiceOfferTests. Только показ: маршрут, поездку,
//  сессию навигации и оповещения правило не трогает.
//

import Foundation

nonisolated enum CarPlayRouteChoiceOffer {

    // MARK: - Есть ли из чего выбирать

    struct Variant: Equatable, Sendable {
        let id: Int
        /// Время, которое осталось ехать (см. `variant(id:…)`): доля показанного
        /// времени по доле пути. Скорость оно считает ровной, поэтому одно не
        /// доказывает «быстрее» — см. `saved`.
        let seconds: Double
        /// Показанное время всего варианта.
        let fullSeconds: Double
        /// Камеры на нашей стороне впереди.
        let cameras: Int
        /// У варианта своя метка («Знакомый», «Спокойнее», «Проще»…).
        let labeled: Bool
        /// Машина стоит на его линии: выбор не обернётся перестроением.
        let nearCar: Bool
    }

    /// Вариант глазами машины, стоящей на нём: время — остаток (доля показанного
    /// времени по доле оставшегося пути), камеры — только впереди. Весь вариант
    /// сравнивать нельзя: разницу мог дать уже проеханный участок, и баннер
    /// обещал бы «быстрее на 6 мин», которых впереди нет (ревью 51). Рядом —
    /// `routeSnapMeters`: порог перестроения (150 м) пускал соседнюю улицу. Метка
    /// варианта («Спокойнее», «Знакомый») сказана про путь от старта и держится,
    /// только пока проехано мало.
    static func variant(id: Int, shownSeconds: Double, distance: Double, along: Double,
                        deviation: Double, cameraAlongs: [Double], labeled: Bool) -> Variant {
        let left = distance > 0 ? max(0, 1 - along / distance) : 1
        return Variant(id: id, seconds: shownSeconds * left, fullSeconds: shownSeconds,
                       cameras: cameraAlongs.count { $0 > along },
                       labeled: labeled && along <= AppConfig.carPlayChoiceOfferMaxMeters,
                       nearCar: deviation <= AppConfig.routeSnapMeters)
    }

    /// На сколько вариант быстрее выбранного наверняка: меньшая из разниц по
    /// остатку и по полному времени. Одна доля пути обманывает при неровной
    /// скорости: A — 25 мин на 25 км, B — 26 мин на 13 км, общие первые 4 км.
    /// По долям 21 и 18 мин, «быстрее на 3», а на деле B на минуту медленнее.
    static func saved(_ other: Variant, over selected: Variant) -> Double {
        min(selected.seconds - other.seconds, selected.fullSeconds - other.fullSeconds)
    }

    /// Заметно ли вариант лучше выбранного: быстрее на ощутимое время, или не
    /// намного дольше, но с меньшим числом камер или со своей меткой. Просто
    /// другая линия с тем же временем — не выбор, а шум.
    static func isWorthChoosing(_ other: Variant, over selected: Variant) -> Bool {
        guard other.nearCar else { return false }
        let faster = max(AppConfig.carPlayChoiceOfferFasterSeconds,
                         selected.seconds * AppConfig.carPlayChoiceOfferFasterShare)
        if saved(other, over: selected) >= faster { return true }
        let slower = max(AppConfig.carPlayChoiceOfferSlowerSeconds,
                         selected.seconds * AppConfig.carPlayChoiceOfferSlowerShare)
        guard other.seconds <= selected.seconds + slower else { return false }
        return other.cameras < selected.cameras || other.labeled
    }

    /// Варианты для списка: выбранный первым и заметно другие. Меньше двух —
    /// выбирать не из чего.
    static func choices(selected: Int, variants: [Variant]) -> [Int] {
        guard let current = variants.first(where: { $0.id == selected }) else { return [] }
        let others = variants.filter { $0.id != selected && isWorthChoosing($0, over: current) }
        return others.isEmpty ? [] : [selected] + others.map(\.id)
    }

    /// Что сказать в баннере: чем лучший из вариантов лучше выбранного.
    enum Gain: Equatable, Sendable {
        case faster(minutes: Int)
        case fewerCameras(Int)
        case other
    }

    static func gain(selected: Int, variants: [Variant], choices: [Int]) -> Gain {
        guard let current = variants.first(where: { $0.id == selected }) else { return .other }
        let others = variants.filter { $0.id != selected && choices.contains($0.id) }
        let best = others.map { saved($0, over: current) }.max() ?? 0
        if best >= AppConfig.carPlayChoiceOfferFasterSeconds { return .faster(minutes: Int((best / 60).rounded())) }
        let fewer = current.cameras - (others.map(\.cameras).min() ?? current.cameras)
        return fewer > 0 ? .fewerCameras(fewer) : .other
    }

    // MARK: - Устарело ли

    /// Выбирать поздно: четверть пути позади — всегда; иначе — когда и маршрут
    /// не свежий, и проехано уже не мало.
    static func isStale(ageSeconds: TimeInterval, along: Double, length: Double) -> Bool {
        if length > 0, along > length * AppConfig.carPlayChoiceOfferMaxShare { return true }
        return ageSeconds > AppConfig.carPlayChoiceOfferMaxAgeSeconds
            && along > AppConfig.carPlayChoiceOfferMaxMeters
    }

    // MARK: - Когда

    struct Situation: Equatable, Sendable {
        /// Опознание набора вариантов; nil — маршрута нет.
        var route: Int?
        var variantCount: Int
        var speedKmh: Double
        /// Метров от старта маршрута и его длина.
        var along: Double
        var length: Double
        /// Системный баннер камеры на подъезде: камера важнее.
        var cameraAhead = false
        /// Наша карта на экране машины, поверх неё ничего, список не открыт.
        var screenFree = true
        /// На телефоне открыта панель маршрута — выбор уже перед водителем.
        var phonePanelOpen = false
        /// Маршрут строится, перестраивается, ждёт ответа об объезде.
        var busy = false
        /// Нет сигнала GPS: скорость сама доходит до 0 и путь замирает — это не
        /// стоянка, а тоннель (баннер встал бы на 60 км/ч).
        var signalLost = false
    }

    enum Decision: Equatable, Sendable {
        case none
        /// Спросить снова через столько секунд (стоя фиксов может не быть).
        case check(after: TimeInterval)
        /// Пора: остаётся проверить варианты и показать баннер.
        case ready
    }

    struct Tracker: Equatable, Sendable {
        private(set) var route: Int?
        /// Вопрос по этому набору закрыт.
        private(set) var spent = false
        private var firstSeen: Date?
        private var standingSince: Date?
        private var standAlong: Double?

        /// Можно ли ещё предложить: только тогда есть смысл следить за скоростью.
        var isOpen: Bool { route != nil && !spent }

        /// - Parameter inJam: стоим в пробке на маршруте; считается только в
        ///   момент решения, а не на каждом фиксе.
        mutating func update(_ situation: Situation, inJam: @autoclosure () -> Bool = false,
                             now: Date) -> Decision {
            if situation.route != route { start(situation.route, now: now) }
            guard route != nil, !spent, situation.variantCount >= 2 else { return .none }
            if situation.signalLost {
                interrupted()
                return .none
            }
            let speed = situation.speedKmh.isFinite ? max(0, situation.speedKmh) : 0
            // Тронулись или ползём: стоянка начнётся заново. Порог выхода выше
            // порога входа — шум GPS стоя не сбрасывает счёт; рывок пробки на
            // малой скорости сбрасывает путь.
            if let from = standAlong,
               speed > AppConfig.carPlayChoiceOfferMoveKmh
                || abs(situation.along - from) >= AppConfig.carPlayChoiceOfferCrawlMeters {
                standingSince = nil
                standAlong = nil
            }
            if standingSince == nil, speed <= AppConfig.carPlayChoiceOfferStandKmh {
                standingSince = now
                standAlong = situation.along
            }
            // Возраст — на начало стоянки: пока ждём подтверждения, маршрут не
            // устаревает, а путь стоя и так не растёт.
            let age = (standingSince ?? now).timeIntervalSince(firstSeen ?? now)
            if CarPlayRouteChoiceOffer.isStale(ageSeconds: age, along: situation.along, length: situation.length) {
                spent = true
                return .none
            }
            guard let since = standingSince else { return .none }
            let stood = now.timeIntervalSince(since)
            guard stood >= AppConfig.carPlayChoiceOfferStandSeconds else {
                return .check(after: AppConfig.carPlayChoiceOfferStandSeconds - stood)
            }
            if situation.busy || situation.cameraAhead || !situation.screenFree
                || situation.phonePanelOpen || inJam() {
                return .check(after: AppConfig.carPlayChoiceOfferRecheckSeconds)
            }
            return .ready
        }

        /// Стоянка прервалась, и что было в это время, мы не знаем: нет сигнала,
        /// машина отключилась (вернулись через час на то же место — не повод для
        /// баннера с порога). Счёт заново, попытка цела.
        mutating func interrupted() {
            standingSince = nil
            standAlong = nil
        }

        /// Вопрос закрыт: баннер встал, список показан, выбор сделан на телефоне
        /// или вариантов не хватило.
        mutating func spend(route key: Int?, now: Date = Date()) {
            if key != route { start(key, now: now) }
            spent = true
        }

        private mutating func start(_ key: Int?, now: Date) {
            route = key
            spent = false
            firstSeen = now
            standingSince = nil
            standAlong = nil
        }
    }
}
