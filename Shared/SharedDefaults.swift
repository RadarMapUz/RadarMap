//
//  SharedDefaults.swift
//  RadarMap
//
//  Обмен данными между приложением и виджетом через App Group.
//
//  В снимке лежит РОВНО то, что виджет рисует. Раньше сюда писались ещё
//  размер базы, её версия и число передвижных точек — их не показывал ни один
//  размер виджета, то есть приложение обновляло мёртвые ключи в конце каждой
//  поездки. Убрано вместе с «максимальной скоростью поездки»: хвастаться
//  104 км/ч на домашнем экране в приложении про штрафы — ровно то, от чего
//  мы отказались в карточке шеринга.
//
//  Виджет по-прежнему ничего не считает и ничем не управляет: приложение
//  кладёт готовые числа при уходе в фон и в конце каждой поездки.
//

import Foundation

enum SharedDefaults {
    nonisolated static let appGroup = "group.uz.radarmap.ios"

    // nonisolated: UserDefaults потокобезопасен, а читают его и виджет, и чистые
    // nonisolated-модели снимков (WidgetCommute) — без прыжка на главный актор.
    nonisolated static var store: UserDefaults? { UserDefaults(suiteName: appGroup) }

    /// Выдан ли App Group на самом деле. Проверять `store == nil` НЕЛЬЗЯ:
    /// `UserDefaults(suiteName:)` возвращает рабочий объект и без права на
    /// группу — просто пишет мимо общего контейнера. Именно поэтому виджет на
    /// телефоне показывал «Готов к поездке» вместо «Нет доступа»: он видел
    /// пустое хранилище и честно считал, что поездок не было. Контейнер же
    /// без entitlement недоступен, и это единственная надёжная проверка.
    nonisolated static var hasAppGroup: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil
    }

    enum Keys {
        static let weekStart = "widget.weekStart"
        static let weekDistance = "widget.weekDistance"
        static let weekTrips = "widget.weekTrips"
        static let weekRating = "widget.weekRating"
        static let weekFineRisk = "widget.weekFineRisk"
        static let dayDistances = "widget.dayDistances"
        static let dayOverspeed = "widget.dayOverspeed"
        static let dayScores = "widget.dayScores"
        static let dayRoad = "widget.dayRoad"
        static let dayPerfect = "widget.dayPerfect"
        static let previousWeekDistance = "widget.previousWeekDistance"
        static let previousWeekRating = "widget.previousWeekRating"
        static let weekCommuteDistance = "widget.weekCommuteDistance"
        static let topRiskPlace = "widget.topRiskPlace"
        static let topRiskPasses = "widget.topRiskPasses"
        static let usualWeekDistance = "widget.usualWeekDistance"
        static let monthDistance = "widget.monthDistance"
        static let lifetimeDistance = "widget.lifetimeDistance"
        static let weekMovingDuration = "widget.weekMovingDuration"
        static let lastTripDistance = "widget.lastTripDistance"
        static let lastTripAt = "widget.lastTripAt"
        static let updatedAt = "widget.updatedAt"
    }

    /// nonisolated: снимок сравнивает чистый WidgetWeek.needsRefresh.
    nonisolated struct Snapshot: Equatable {
        /// Начало недели, за которую здесь цифры. Без него виджет не может
        /// отличить «эта неделя» от «та, на которой человек последний раз
        /// открывал приложение», — и всю новую неделю честно показывал бы
        /// прошлые числа как текущие.
        var weekStart: Date?
        var weekDistance = 0.0
        var weekTrips = 0
        /// −1 — рейтинга нет (на неделе не ездили): UserDefaults не отличает
        /// «нет значения» от нуля, а ноль здесь был бы враньём про худшую езду.
        var weekRating = -1
        var weekFineRisk = 0.0
        /// Километры по дням недели, в порядке календаря пользователя (7 чисел).
        var dayDistances = [Double](repeating: 0, count: 7)
        /// Был ли в этот день хоть один штрафуемый проезд камеры.
        var dayOverspeed = [Bool](repeating: false, count: 7)
        /// Балл дня, −1 — оценки нет; доля обычного дня 0…1; день без замечаний.
        /// Это кольца дня, те же, что в календаре «Итогов».
        var dayScores = [Int](repeating: -1, count: 7)
        var dayRoad = [Double](repeating: 0, count: 7)
        var dayPerfect = [Bool](repeating: false, count: 7)
        /// Место, где за неделю потеряно больше всего, и число проездов там.
        var topRiskPlace: String?
        var topRiskPasses = 0
        /// «Обычная неделя» — медиана километров за предыдущие недели. К ней
        /// заполняется кольцо: цель, которую человек не ставил, ему и не нужна,
        /// а своя привычная норма — понятная точка отсчёта.
        var usualWeekDistance = 0.0
        /// Прошлая неделя — чем говорить в понедельник вместо «нет данных».
        var previousWeekDistance = 0.0
        var previousWeekRating = -1
        var monthDistance = 0.0
        /// Пожизненный пробег с приложением — единственное число, которое
        /// только растёт, и потому приятное.
        var lifetimeDistance = 0.0
        var weekMovingDuration: TimeInterval = 0
        /// Из километров недели — дорога дом–работа. Без координат: только сумма.
        var weekCommuteDistance = 0.0
        /// Последняя поездка — единственное, что можно честно показать, пока
        /// неделя ещё не набралась: сравнивать не с чем, а факт уже есть.
        var lastTripDistance = 0.0
        var lastTripAt: Date?
        var updatedAt: Date?
        /// Доступен ли общий контейнер. false — App Group не выдан подписью
        /// (личная команда его не даёт), и виджет обязан сказать это прямо, а
        /// не показывать нули: «вы не ездили» и «мне не дали данные» — разные
        /// вещи с разными действиями пользователя.
        var hasAccess = true
    }

    static func write(_ snapshot: Snapshot) {
        guard let store else { return }
        store.set(snapshot.weekStart, forKey: Keys.weekStart)
        store.set(snapshot.weekDistance, forKey: Keys.weekDistance)
        store.set(snapshot.weekTrips, forKey: Keys.weekTrips)
        store.set(snapshot.weekRating, forKey: Keys.weekRating)
        store.set(snapshot.weekFineRisk, forKey: Keys.weekFineRisk)
        store.set(WidgetWeek.padded(snapshot.dayDistances), forKey: Keys.dayDistances)
        store.set(WidgetWeek.padded(snapshot.dayOverspeed), forKey: Keys.dayOverspeed)
        store.set(WidgetWeek.padded(snapshot.dayScores, fill: -1), forKey: Keys.dayScores)
        store.set(WidgetWeek.padded(snapshot.dayRoad), forKey: Keys.dayRoad)
        store.set(WidgetWeek.padded(snapshot.dayPerfect), forKey: Keys.dayPerfect)
        store.set(snapshot.previousWeekDistance, forKey: Keys.previousWeekDistance)
        store.set(snapshot.previousWeekRating, forKey: Keys.previousWeekRating)
        store.set(snapshot.weekCommuteDistance, forKey: Keys.weekCommuteDistance)
        store.set(snapshot.topRiskPlace, forKey: Keys.topRiskPlace)
        store.set(snapshot.topRiskPasses, forKey: Keys.topRiskPasses)
        store.set(snapshot.usualWeekDistance, forKey: Keys.usualWeekDistance)
        store.set(snapshot.monthDistance, forKey: Keys.monthDistance)
        store.set(snapshot.lifetimeDistance, forKey: Keys.lifetimeDistance)
        store.set(snapshot.weekMovingDuration, forKey: Keys.weekMovingDuration)
        store.set(snapshot.lastTripDistance, forKey: Keys.lastTripDistance)
        store.set(snapshot.lastTripAt, forKey: Keys.lastTripAt)
        store.set(Date(), forKey: Keys.updatedAt)
    }

    static func read() -> Snapshot {
        guard hasAppGroup, let store else { return Snapshot(hasAccess: false) }
        return Snapshot(
            weekStart: store.object(forKey: Keys.weekStart) as? Date,
            weekDistance: store.double(forKey: Keys.weekDistance),
            weekTrips: store.integer(forKey: Keys.weekTrips),
            // Ключа ещё нет (первый запуск после обновления) — integer даёт 0,
            // а это «настоящий ноль» рейтинга; отличаем отсутствием ключа.
            weekRating: store.object(forKey: Keys.weekRating) == nil
                ? -1 : store.integer(forKey: Keys.weekRating),
            weekFineRisk: store.double(forKey: Keys.weekFineRisk),
            dayDistances: WidgetWeek.padded(store.array(forKey: Keys.dayDistances) as? [Double] ?? []),
            dayOverspeed: WidgetWeek.padded(store.array(forKey: Keys.dayOverspeed) as? [Bool] ?? []),
            dayScores: WidgetWeek.padded(store.array(forKey: Keys.dayScores) as? [Int] ?? [], fill: -1),
            dayRoad: WidgetWeek.padded(store.array(forKey: Keys.dayRoad) as? [Double] ?? []),
            dayPerfect: WidgetWeek.padded(store.array(forKey: Keys.dayPerfect) as? [Bool] ?? []),
            topRiskPlace: store.string(forKey: Keys.topRiskPlace),
            topRiskPasses: store.integer(forKey: Keys.topRiskPasses),
            usualWeekDistance: store.double(forKey: Keys.usualWeekDistance),
            previousWeekDistance: store.double(forKey: Keys.previousWeekDistance),
            previousWeekRating: store.object(forKey: Keys.previousWeekRating) == nil
                ? -1 : store.integer(forKey: Keys.previousWeekRating),
            monthDistance: store.double(forKey: Keys.monthDistance),
            lifetimeDistance: store.double(forKey: Keys.lifetimeDistance),
            weekMovingDuration: store.double(forKey: Keys.weekMovingDuration),
            weekCommuteDistance: store.double(forKey: Keys.weekCommuteDistance),
            lastTripDistance: store.double(forKey: Keys.lastTripDistance),
            lastTripAt: store.object(forKey: Keys.lastTripAt) as? Date,
            updatedAt: store.object(forKey: Keys.updatedAt) as? Date
        )
    }
}

// MARK: - Чистая логика виджета

/// Всё, что виджету надо РЕШИТЬ, а не нарисовать. Отдельно и без SwiftUI:
/// виджет не имеет права считать данные, но обязан правильно понимать, что
/// ему прислали (см. `WidgetSnapshotTests`).
/// Что виджету вообще есть сказать. Проектировать надо было отсюда: полная
/// неделя выглядит хорошо и сама, а живёт виджет в основном в двух других
/// состояниях — понедельник, первая неделя, отпуск.
nonisolated enum WidgetState: Equatable {
    /// App Group не выдан подписью — данных нет и не будет, пока это не чинят.
    case noAccess
    /// Поездок ещё не было вообще. Ноль километров — не факт, а его отсутствие.
    case empty
    /// На этой неделе поездок нет, а раньше были: водитель с историей в
    /// понедельник, а не первый день в приложении.
    case newWeek
    /// Поездки есть, но нормы и формы недели ещё нет: сравнивать не с чем.
    case few
    /// Полная неделя: дни и норма.
    case full
}

nonisolated enum WidgetWeek {

    // MARK: - Процент к прошлому периоду (31E)

    /// Процент — только если прошлый период был не меньше этого: «+178 %»
    /// от девяти километров — арифметика, а не новость.
    static let percentMinPreviousMeters = 20_000.0
    /// …и периоды соизмеримы: отношение не дальше этого множителя.
    static let percentMaxRatio = 2.0

    /// Изменение километров процентом — одно правило на «Итоги», карточку
    /// «Поделиться» и виджет: оба окна целые (идущая неделя против целой в
    /// среду всегда «−60 %»), прошлое не крошечное и не отличается в разы.
    /// nil — процент здесь врал бы; тогда говорят километрами или молчат.
    static func comparablePercent(distance: Double, previous: Double, periodComplete: Bool) -> Int? {
        guard periodComplete, previous >= percentMinPreviousMeters else { return nil }
        let ratio = distance / previous
        guard ratio <= percentMaxRatio, ratio >= 1 / percentMaxRatio else { return nil }
        return Int(((ratio - 1) * 100).rounded())
    }

    /// Когда виджету самому перечитать снимок: в начале следующих суток (с
    /// минутой запаса). Новые цифры приносит приложение (reloadTimelines),
    /// а сам виджет должен заметить только смену дня и недели.
    static func nextRefresh(after now: Date, calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            ?? now.addingTimeInterval(86_400)
        return tomorrow.addingTimeInterval(60)
    }

    /// Перезаписать ли снимок и перезагрузить виджет. Только когда цифры
    /// другие: у WidgetKit дневной бюджет, и, выбранный впустую, он кончался
    /// ровно к концу поездки (аудит 11.10). Сутки без поездок снимок не
    /// портят: поездки пишутся сами, а смену дня виджет замечает сам.
    static func needsRefresh(previous: SharedDefaults.Snapshot, next: SharedDefaults.Snapshot) -> Bool {
        guard previous.hasAccess, previous.updatedAt != nil else { return true }
        var old = previous, new = next
        old.updatedAt = nil
        new.updatedAt = nil
        return old != new
    }

    /// Сколько дней недели были ездовыми.
    static func activeDayCount(_ distances: [Double]) -> Int {
        padded(distances).filter { $0 > 0 }.count
    }

    /// Состояние виджета. Порог «мало данных» — меньше двух ездовых дней ИЛИ
    /// нет накопленной нормы: и то и другое означает, что сравнивать не с чем,
    /// а значит ни «в среднем», ни «из обычных» показывать нельзя.
    static func state(_ snapshot: SharedDefaults.Snapshot) -> WidgetState {
        guard snapshot.hasAccess else { return .noAccess }
        guard snapshot.weekTrips > 0 || snapshot.weekDistance > 0 else {
            let hasHistory = snapshot.lifetimeDistance > 0 || snapshot.previousWeekDistance > 0
                || snapshot.usualWeekDistance > 0 || snapshot.lastTripAt != nil
            return hasHistory ? .newWeek : .empty
        }
        let days = activeDayCount(snapshot.dayDistances)
        return days >= 2 && snapshot.usualWeekDistance > 1000 ? .full : .few
    }

    /// Красить день красным есть смысл, только когда в неделе есть с чем его
    /// сравнить. Единственный столбик красным превращает виджет в аварийный
    /// щит, хотя случилось обычное.
    static func marksOverspeedDays(_ distances: [Double]) -> Bool {
        activeDayCount(distances) >= 2
    }

    /// Рисовать ли столбики дней. С двух ездовых дней — форма недели уже
    /// есть, даже если нормы ещё нет: «мало данных» (`.few`) бывает и всю
    /// первую неделю после установки, и подсказка «столбики — со второго
    /// дня» на пятый день за рулём была неправдой (ревью 19.10).
    static func showsBars(_ distances: [Double]) -> Bool {
        activeDayCount(distances) >= 2
    }

    /// Показывать ли «всего». Пока пожизненный пробег не ощутимо больше
    /// месячного, это то же число другими словами — а у нового пользователя
    /// так всегда: счёт начался с установки.
    static func showsLifetime(month: Double, lifetime: Double) -> Bool {
        lifetime > month * 1.5 && lifetime > 0
    }

    /// Ровно семь значений: короткий массив дополняется, длинный обрезается.
    /// Данные приходят из App Group, то есть из другого процесса и, возможно,
    /// из прошлой версии приложения — доверять их длине нельзя.
    static func padded<T>(_ values: [T], count: Int = 7, fill: T) -> [T] {
        if values.count == count { return values }
        if values.count > count { return Array(values.prefix(count)) }
        return values + [T](repeating: fill, count: count - values.count)
    }

    static func padded(_ values: [Double]) -> [Double] { padded(values, fill: 0) }
    static func padded(_ values: [Bool]) -> [Bool] { padded(values, fill: false) }

    /// Снимок всё ещё про ТЕКУЩУЮ неделю? Если нет — показывать его цифры
    /// нельзя: это прошлая неделя, выданная за эту.
    static func isCurrentWeek(_ weekStart: Date?, now: Date,
                              calendar: Calendar = .current) -> Bool {
        guard let weekStart,
              let interval = calendar.dateInterval(of: .weekOfYear, for: now)
        else { return false }
        return calendar.isDate(weekStart, inSameDayAs: interval.start)
            || (weekStart >= interval.start && weekStart < interval.end)
    }

    /// Подпись к норме. Идущая неделя сравнивается с целой обычной только
    /// как «118 из обычных 165»: «на 28 % меньше» в четверг неправда, водитель
    /// не отстаёт, неделя просто не кончилась. «Больше» — уже факт.
    enum UsualLine: Equatable {
        case none
        case asUsual
        case ofUsual(Double)
        case above(percent: Int)
    }

    static func usualLine(distance: Double, usual: Double) -> UsualLine {
        guard usual > 1000, distance > 0 else { return .none }
        let share = distance / usual
        if share > 1.05 { return .above(percent: Int(((share - 1) * 100).rounded())) }
        return share >= 0.95 ? .asUsual : .ofUsual(usual)
    }

    /// Сколько дней назад: 0 — сегодня, 1 — вчера. Для абсолютной подписи:
    /// виджет перерисовывается раз в сутки, «2 часа назад» замерло бы.
    static func daysAgo(_ date: Date, now: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                to: calendar.startOfDay(for: now)).day ?? 0
    }

    /// Кольца дня; nil — в этот день не ездили.
    struct DayRing: Equatable {
        let score: Int?
        let road: Double
        let fine: Bool
        let perfect: Bool
    }

    static func dayRings(_ snapshot: SharedDefaults.Snapshot) -> [DayRing?] {
        let distances = padded(snapshot.dayDistances), scores = padded(snapshot.dayScores, fill: -1)
        let road = padded(snapshot.dayRoad), fines = padded(snapshot.dayOverspeed)
        let perfect = padded(snapshot.dayPerfect)
        let marks = marksOverspeedDays(distances)
        return (0..<7).map { index in
            guard distances[index] > 0 else { return nil }
            return DayRing(score: scores[index] >= 0 ? scores[index] : nil,
                           road: min(1, max(0, road[index])),
                           fine: marks && fines[index], perfect: perfect[index])
        }
    }

    enum DayDot: Equatable {
        case none, driven, today
    }

    /// Дни точками на экране блокировки: сегодня, если ездили, ярче остальных.
    static func dayDots(_ distances: [Double], today: Int?) -> [DayDot] {
        padded(distances).enumerated().map { index, distance in
            guard distance > 0 else { return .none }
            return index == today ? .today : .driven
        }
    }

    struct Split: Equatable {
        let commute: Double
        let other: Double
        var commuteShare: Double { commute / (commute + other) }
    }

    /// Дорога дом–работа и всё остальное. Показывать только когда есть оба:
    /// полоса из одной половины — это не сравнение.
    static func split(_ snapshot: SharedDefaults.Snapshot) -> Split? {
        let total = snapshot.weekDistance, commute = min(snapshot.weekCommuteDistance, total)
        guard commute >= 1000, total - commute >= 1000 else { return nil }
        return Split(commute: commute, other: total - commute)
    }

    /// Высоты столбиков 0…1 от самого длинного дня. День без поездок — 0
    /// (рисуется тонкой полоской: день был, просто не ездили — исчезнуть он
    /// не должен, иначе неделя выглядит короче, чем была).
    static func barHeights(_ distances: [Double]) -> [Double] {
        let values = padded(distances)
        guard let peak = values.max(), peak > 0 else {
            return [Double](repeating: 0, count: values.count)
        }
        return values.map { max(0, $0) / peak }
    }

    /// Какой по счёту день недели сегодня (0…6) — для обводки «сегодня».
    /// nil, если снимок не про текущую неделю: обводить там нечего.
    static func todayIndex(_ weekStart: Date?, now: Date,
                           calendar: Calendar = .current) -> Int? {
        guard isCurrentWeek(weekStart, now: now, calendar: calendar),
              let interval = calendar.dateInterval(of: .weekOfYear, for: now),
              let days = calendar.dateComponents([.day], from: interval.start,
                                                 to: calendar.startOfDay(for: now)).day,
              (0...6).contains(days)
        else { return nil }
        return days
    }

    /// Заполнение кольца к обычной неделе, 0…1. Перепробег НЕ переполняет
    /// кольцо: полное кольцо означает «как обычно», а «в полтора раза больше»
    /// говорится цифрой рядом, а не вторым витком, который читается как ошибка.
    static func usualWeekProgress(distance: Double, usual: Double) -> Double {
        guard usual > 0, distance > 0 else { return 0 }
        return min(1, distance / usual)
    }

    /// Средний день недели — по дням, КОГДА ЕЗДИЛИ. Делить на семь нечестно:
    /// человек, который ездит по будням, получил бы заниженную норму и решил,
    /// что стал ездить меньше.
    static func averagePerActiveDay(_ distances: [Double]) -> Double {
        let active = padded(distances).filter { $0 > 0 }
        guard !active.isEmpty else { return 0 }
        return active.reduce(0, +) / Double(active.count)
    }

    /// Медиана — «обычная неделя». Именно медиана, а не среднее: одна поездка
    /// в Самарканд не должна сдвинуть норму так, чтобы все следующие недели
    /// выглядели провальными.
    static func median(_ values: [Double]) -> Double {
        let sorted = values.filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1
            ? sorted[middle]
            : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// Подписи дней в порядке календаря пользователя («пн»…«вс» или «вс»…«сб»).
    /// Порядок — от календаря (он же режет неделю на столбики), язык — от
    /// приложения: при регионе «США» под русскими цифрами стояли «S M T W».
    static func dayLabels(calendar: Calendar = .current,
                          locale: Locale = NumberFormat.locale) -> [String] {
        var named = calendar
        named.locale = locale
        let symbols = named.veryShortStandaloneWeekdaySymbols
        guard symbols.count == 7 else { return symbols }
        let first = calendar.firstWeekday - 1        // 1…7 → 0…6
        return (0..<7).map { symbols[($0 + first) % 7] }
    }
}
