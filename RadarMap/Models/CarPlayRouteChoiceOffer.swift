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
        /// Время, которое видит водитель.
        let seconds: Double
        /// Камеры на нашей стороне.
        let cameras: Int
        /// У варианта своя метка («Знакомый», «Спокойнее», «Проще»…).
        let labeled: Bool
        /// Машина стоит на его линии: выбор не обернётся перестроением.
        let nearCar: Bool
    }

    /// Заметно ли вариант лучше выбранного: быстрее на ощутимое время, или не
    /// намного дольше, но с меньшим числом камер или со своей меткой. Просто
    /// другая линия с тем же временем — не выбор, а шум.
    static func isWorthChoosing(_ other: Variant, over selected: Variant) -> Bool {
        guard other.nearCar else { return false }
        let faster = max(AppConfig.carPlayChoiceOfferFasterSeconds,
                         selected.seconds * AppConfig.carPlayChoiceOfferFasterShare)
        if other.seconds <= selected.seconds - faster { return true }
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
        let saved = current.seconds - (others.map(\.seconds).min() ?? current.seconds)
        if saved >= AppConfig.carPlayChoiceOfferFasterSeconds { return .faster(minutes: Int((saved / 60).rounded())) }
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
