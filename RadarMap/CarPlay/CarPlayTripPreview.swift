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
        let cameras = String(format: String(localized: "камер: %lld"), variant.cameras.count)
        let facts = [variant.distanceText, cameras, variant.trafficNote]
            .compactMap { $0 }.joined(separator: " · ")
        let short = "\(variant.distanceText) · \(cameras)"
        let reason = all.count > 1 ? RoutePanel.reason(variant, among: all) : nil
        return ChoiceText(
            summary: [head.map { "\($0) · \(eta)" }, eta].compactMap { $0 },
            additional: [reason.map { "\($0) · \(facts)" }, facts, short].compactMap { $0 },
            selection: [[head, eta, variant.distanceText].compactMap { $0 }.joined(separator: " · "), eta])
    }

    /// Цвет оставшегося времени по пробкам (CPTimeRemainingColor).
    enum TimeColor: Equatable {
        /// Данных о пробках нет — цвет системы, а не «зелёный»: зелёный был
        /// бы утверждением «пробок нет», которого мы не знаем.
        case standard
        case green, orange, red
    }

    static func timeColor(trafficDelay: TimeInterval?) -> TimeColor {
        guard let delay = trafficDelay else { return .standard }
        if delay < AppConfig.carPlayTrafficGreenSeconds { return .green }
        if delay < AppConfig.carPlayTrafficOrangeSeconds { return .orange }
        return .red
    }

    /// Показывать ли выбор: только пока машина стоит или ползёт.
    static func shouldPreview(speedKmh: Double) -> Bool {
        !(speedKmh.isFinite && speedKmh >= AppConfig.carPlayPreviewMaxKmh)
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
