//
//  OfflineOffer.swift
//  RadarMap
//
//  «Скачать карту этой области?» — по одному разу на область.
//
//  Скачивание — выбор человека, а не обязанность: камеры предупреждают и
//  без него. Поэтому приложение спрашивает про область ОДИН раз, в спокойный
//  момент, и «Не сейчас» закрывает вопрос о ней навсегда. Но приехал в другую
//  область — вопрос о ней новый: там связи может не быть уже сегодня. Дальше
//  область качают в Настройки → Карта → Офлайн-карты, если захотят.
//
//  Спокойный момент — это:
//  - онбординг позади (человеку и так задали достаточно вопросов);
//  - карта — наша (на карте Apple офлайн-файлы ничего не меняют);
//  - не за рулём: решение про мегабайты не принимают на ходу;
//  - сеть не урезана: Wi-Fi или сотовая, если область в разумном размере
//    (`offlineOfferCellularMaxBytes`), и никогда в «Экономии данных»;
//  - область известна и ещё не скачана и не качается.
//
//  Чистое решение — покрыто OfflineOfferTests.
//

import CoreLocation

nonisolated enum OfflineOffer {

    struct Situation: Equatable {
        var onboarded: Bool
        var answered: Bool
        var ownMap: Bool
        var driving: Bool
        var online: Bool
        var expensiveNetwork: Bool
        /// «Экономия данных»: не предлагаем ни за какой размер.
        var constrainedNetwork = false
        /// Размер области; по умолчанию — неизвестен, и сотовая тогда нельзя.
        var regionBytes: Int64 = .max
        /// Область найдена в каталоге и ещё не скачана и не качается.
        var regionAvailable: Bool
        /// Внизу уже стоит «Домой / На работу» — действие этой минуты.
        /// Мегабайты подождут: больше двух карточек внизу не бывает (5.9).
        var suggestionShown = false
    }

    static func shouldOffer(_ s: Situation) -> Bool {
        s.onboarded && !s.answered && s.ownMap && !s.driving
            && s.online && networkAllows(s) && s.regionAvailable && !s.suggestionShown
    }

    private static func networkAllows(_ s: Situation) -> Bool {
        guard !s.constrainedNetwork else { return false }
        return !s.expensiveNetwork || s.regionBytes <= AppConfig.offlineOfferCellularMaxBytes
    }

    /// Точка для предложения: где человек сейчас — ему нужна карта этого
    /// места; без точки — дом.
    static func offerPoint(current: CLLocationCoordinate2D?, home: CLLocationCoordinate2D?,
                           learnedHome: CLLocationCoordinate2D?) -> CLLocationCoordinate2D? {
        current ?? home ?? learnedHome
    }

    /// Отвечали ли про эту область. Прежний общий флаг был про область дома,
    /// а дом неизвестен — про единственное, о чём спрашивали: новых вопросов
    /// в родной области он не добавит, а чужая область спросится один раз.
    static func wasAnswered(regionID: String, answeredRegions: Set<String>,
                            legacyAnswered: Bool, homeRegionID: String?) -> Bool {
        if answeredRegions.contains(regionID) { return true }
        guard legacyAnswered else { return false }
        return homeRegionID == nil || homeRegionID == regionID
    }

    /// Хранение в `Storage.offlineOfferRegions`: id областей без запятых.
    static func decodeRegions(_ stored: String?) -> Set<String> {
        Set((stored ?? "").split(separator: ",").map(String.init))
    }

    static func encodeRegions(_ regions: Set<String>) -> String {
        regions.sorted().joined(separator: ",")
    }
}
