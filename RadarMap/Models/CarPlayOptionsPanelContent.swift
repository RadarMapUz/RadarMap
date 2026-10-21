//
//  CarPlayOptionsPanelContent.swift
//  RadarMap
//
//  Что лежит в панели «…» плашки прибытия в машине (25.H1, iOS 27).
//
//  С iOS 27 у CPNavigationSession есть `optionsPanel` — CPMapPanel, которую
//  система открывает по «…» в оценках поездки (CPNavigationSession.h), поверх
//  карты, без ухода с неё. Новых кнопок в баре не нужно, и туда легло то, что
//  за рулём ищут чаще всего:
//    • «Камеры впереди» — ближайшие по маршруту с остатком пути (тот же
//      список, что «Куда» → «Камеры», `RouteCamerasAhead`), справочный;
//    • «Звук» — одной строкой: выключить, а из тишины — вернуть то, что было
//      до неё (как кнопка звука, `CarPlaySoundChoice`);
//    • «Завершить маршрут» — главная кнопка панели; поездка и оповещения о
//      камерах остаются (как «Отменить маршрут» в «Куда»).
//
//  Каждое обновление панели — сообщение в машину, а расстояния меняются на
//  каждом фиксе: пока панель открыта — не чаще `carPlayOptionsPanelRefreshSeconds`,
//  закрыта — только при смене состава (камеры, звук), чтобы открытая по «…»
//  панель сразу была верной.
//
//  Чистая логика; CarPlayOptionsPanelContentTests.
//

import CoreLocation

enum CarPlayOptionsPanelContent {

    struct Row: Equatable {
        let id: Int
        let title: String
        let detail: String
    }

    struct Content: Equatable {
        let cameras: [Row]
        let sound: CarPlaySoundChoice

        /// Состав без цифр: какие камеры и какой звук.
        var shape: Shape { Shape(ids: cameras.map(\.id), sound: sound) }
    }

    struct Shape: Equatable {
        let ids: [Int]
        let sound: CarPlaySoundChoice
    }

    static func content(ahead: [RouteCamerasAhead.Item], sound: CarPlaySoundChoice,
                        limit: Int = AppConfig.carPlayOptionsPanelCameras,
                        distance: ((Double) -> String)? = nil) -> Content {
        let distance = distance ?? { Formatting.distance($0) }
        return Content(cameras: ahead.prefix(max(0, limit)).map { item in
                    Row(id: item.camera.id,
                        title: "\(distance(item.meters)) · \(item.camera.kind.displayName)",
                        detail: item.camera.displayTitle)
                },
                sound: sound)
    }

    /// Пора ли переписать панель.
    static func shouldRefresh(shown: Content?, new: Content, sinceLast: TimeInterval, visible: Bool,
                              interval: TimeInterval = AppConfig.carPlayOptionsPanelRefreshSeconds) -> Bool {
        guard let shown else { return true }
        guard shown != new else { return false }
        if shown.shape != new.shape { return true }
        return visible && sinceLast >= interval
    }

    /// Строка звука: что включит касание. Звук есть — тишина; тишина — то,
    /// что было до неё в этой машине (`before`), иначе «умный» голос.
    static func soundToggle(current: CarPlaySoundChoice, before: CarPlaySoundChoice?) -> CarPlaySoundChoice {
        guard current == .silent else { return .silent }
        guard let before, before != .silent else { return .smart }
        return before
    }
}
