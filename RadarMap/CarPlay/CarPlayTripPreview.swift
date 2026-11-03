//
//  CarPlayTripPreview.swift
//  RadarMap
//
//  Выбор маршрута на экране машины — тексты вариантов и правила показа.
//
//  До 2.2.16 машина после «Куда» строила ОДИН маршрут и сразу ехала: на
//  телефоне у водителя 2–3 варианта с метками «Быстрый / Знакомый / Меньше
//  камер», в машине — ни одного выбора («при смене места пусть предлагает
//  маршруты», владелец, 12.10). Теперь — стандартный экран CarPlay
//  «предпросмотр поездки», как у Apple и Google: варианты с нашими метками
//  и временем с пробками, «Поехали».
//
//  Два правила, чтобы выбор не мешал ехать:
//    * машина уже едет — выбора нет, ведём рекомендованным: читать список
//      вариантов на ходу — ровно то, от чего CarPlay бережёт водителя;
//    * тронулись, пока выбор на экране, — выбор принят (рекомендованный или
//      тот, что водитель успел отметить): «поехали» сказано педалью.
//
//  Тексты и правила — без CarPlay: покрыто CarPlayTripPreviewTests.
//

import Foundation

enum CarPlayTripPreview {

    /// Строки варианта для CPRouteChoice — каждая от длинной к короткой
    /// (машина покажет ту, что влезет).
    struct ChoiceText: Equatable {
        let summary: [String]
        let additional: [String]
        let selection: [String]
    }

    static func text(for variant: RouteService.Variant,
                     among all: [RouteService.Variant]) -> ChoiceText {
        let eta = variant.etaText
        let head = variant.assessment.labels.first.map { RoutePanel.title($0, variant) }
        let cameras = String(format: String(localized: "камер: %lld"), variant.ourCameraCount)
        let facts = [variant.distanceText, cameras, variant.trafficNote]
            .compactMap { $0 }.joined(separator: " · ")
        let short = "\(variant.distanceText) · \(cameras)"
        let reason = all.count > 1 ? RoutePanel.reason(variant, among: all) : nil
        return ChoiceText(
            summary: [head.map { "\($0) · \(eta)" }, eta].compactMap { $0 },
            additional: [reason.map { "\($0) · \(facts)" }, facts, short].compactMap { $0 },
            // Выбранный вариант на карточке машины — то же, что карточка
            // телефона (27.D): ярлык, время, путь, камеры; короче — без камер.
            selection: [[head, eta, variant.distanceText, cameras].compactMap { $0 }.joined(separator: " · "),
                        [head, eta, variant.distanceText].compactMap { $0 }.joined(separator: " · "), eta])
    }

    /// Цвет оставшегося времени по пробкам (CPTimeRemainingColor).
    enum TimeColor: Equatable {
        /// Данных о пробках нет — цвет системы, а не «зелёный»: зелёный был
        /// бы утверждением «пробок нет», которого мы не знаем.
        case standard
        case green, orange, red
    }

    /// Тот же цвет, что у времени варианта на телефоне (RoutePreview.trafficTone).
    static func timeColor(trafficDelay: TimeInterval?) -> TimeColor {
        switch RoutePreview.trafficTone(delay: trafficDelay) {
        case .unknown: return .standard
        case .free:    return .green
        case .slow:    return .orange
        case .heavy:   return .red
        }
    }

    /// Показывать ли выбор: только пока машина стоит или ползёт.
    static func shouldPreview(speedKmh: Double) -> Bool {
        !(speedKmh.isFinite && speedKmh >= AppConfig.carPlayPreviewMaxKmh)
    }

    /// Что сейчас на карточке выбора в машине (40I, дефект 35).
    ///
    /// `CPRouteChoice` после показа не меняется: ни текст, ни порядок, ни
    /// выделенный вариант. До 40I выбор строился один раз, а поздние пробки
    /// двигали «Быстрый» и выбор на телефоне — линия в машине уходила на
    /// новый вариант, карточка выделяла старый с чужой меткой, и автостарт
    /// на ходу вёл не тем, что видел водитель. Теперь показ выбора в машине —
    /// касание (`RouteService.noteChoiceTouched`): метки и выбор заморожены,
    /// а время вариантов живёт дальше — этим правилом.
    struct Shown: Equatable {
        /// Опознание набора: номера вариантов — индексы и совпадают между
        /// наборами, поэтому — линии варианта (`ObjectIdentifier` полилинии),
        /// по порядку номеров. Другой набор к той же цели (перестроили на
        /// телефоне) — всегда пересоздание.
        let set: [ObjectIdentifier]
        /// Варианты в порядке карточки (выбранный — первым).
        let order: [Int]
        /// Строки каждого варианта: в них время, оно меняется с пробками.
        let texts: [Int: ChoiceText]
        /// Выделенный в машине вариант.
        private(set) var highlighted: Int
        /// Водитель сам перевёл выделение в машине (крутилкой или касанием).
        private(set) var pickedInCar = false

        init(set: [ObjectIdentifier], order: [Int], texts: [Int: ChoiceText]) {
            self.set = set
            self.order = order
            self.texts = texts
            highlighted = order.first ?? 0
        }

        /// Система сообщила выделенный вариант. Тот же, что выделен, — не
        /// выбор водителя: система может прислать его и при первом показе.
        mutating func picked(_ id: Int) {
            if id != highlighted { pickedInCar = true }
            highlighted = id
        }
    }

    /// Опознание набора вариантов — линии по порядку номеров.
    static func identity(_ variants: [RouteService.Variant]) -> [ObjectIdentifier] {
        variants.sorted { $0.id < $1.id }.map { ObjectIdentifier($0.polyline) }
    }

    enum Refresh: Equatable {
        /// Только оценки выделенного варианта (`update(_:for:with:)`).
        case estimates
        /// Пересоздать выбор: карточка показывает не то, чем поедем, или
        /// устарело время в строках.
        case rebuild
    }

    /// Что сделать с выбором в машине, когда у маршрута что-то сменилось.
    /// `selected` — вариант, которым поедем (`RouteService.selectedID`);
    /// `set` — опознание набора сейчас; `texts` — строки вариантов сейчас.
    static func refresh(_ shown: Shown, selected: Int, set: [ObjectIdentifier],
                        texts: [Int: ChoiceText]) -> Refresh {
        // Другой набор или выбор сделан не здесь (на телефоне) — карточка
        // обязана выделять то, чем поедем, иначе «Поехали» и автостарт на
        // ходу поведут не тем, что видно. Касание в машине было по старому
        // набору и новый не защищает.
        guard set == shown.set, Set(texts.keys) == Set(shown.order),
              selected == shown.highlighted else { return .rebuild }
        // Время в строках устарело. Пересоздание сбрасывает фокус крутилки,
        // поэтому — только пока водитель не трогал выбор; потом время
        // выделенного варианта идёт оценками, которые машина печатает сама.
        if texts != shown.texts, !shown.pickedInCar { return .rebuild }
        return .estimates
    }

    /// Тронулись, пока выбор на экране: принять его, когда скорость держится
    /// `carPlayPreviewAutoStartSeconds` — один всплеск GPS не считается.
    struct MovingWatch: Equatable {
        private(set) var since: Date?

        mutating func update(speedKmh: Double, at now: Date) -> Bool {
            guard speedKmh.isFinite, speedKmh >= AppConfig.carPlayPreviewAutoStartKmh else {
                since = nil
                return false
            }
            let start = since ?? now
            since = start
            return now.timeIntervalSince(start) >= AppConfig.carPlayPreviewAutoStartSeconds
        }
    }
}
