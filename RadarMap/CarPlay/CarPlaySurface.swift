//
//  CarPlaySurface.swift
//  RadarMap
//
//  Три места, где в машине стоит наша карта, и чем они различаются.
//
//  • Экран машины (`car`) — навигатор: наклон по скорости, жесты шаблона,
//    дома по настройке, полная частота кадров у камеры и манёвра.
//  • Плитка главного экрана (`dashboard`) — только взгляд: без жестов, «я»
//    по своей доле высоты; во «Вождении 3D» — тот же облик, что у машины, с
//    потолком 45° и упрощением первой на тёплом телефоне (Drive3D.TileLevel).
//  • Приборка (`cluster`, 25.H2) — карта под глазами водителя, в окне
//    кластера рядом со спидометром машины. Она идёт ВТОРОЙ картой на движке
//    одновременно с экраном машины или плиткой (телефонная карта при
//    подключённой машине уже уступает — RootView), и картинка в машину
//    рисуется на телефоне в держателе под солнцем. Поэтому всё, что тянет
//    тайлы и кадры, здесь выключено: плоско (наклон тянет к горизонту втрое
//    больше тайлов), без домов, только дорога, малая частота кадров. Камеры,
//    маршрут и знак лимита — остаются: ради них приборка и нужна.
//
//  Чистое решение, покрыто CarPlayClusterTests.
//

import Foundation

nonisolated enum CarPlaySurface: Equatable, Sendable {
    case car, dashboard, cluster

    /// Метка строки здоровья карты в журнале (engineHealthLogSeconds, Log.carplay).
    var healthTag: String {
        switch self {
        case .car:       "машина"
        case .dashboard: "плитка"
        case .cluster:   "приборка"
        }
    }

    /// Жесты движка. В окне CarPlay касаний нет вовсе, но плитка и приборка —
    /// только для взгляда: случайный жест снимал бы слежение, а вернуть его
    /// там нечем (нет «к себе»).
    var interactive: Bool { self == .car }

    /// Наклон по скорости. Приборка — всегда сверху: экран маленький, а
    /// наклон — лишние тайлы у горизонта на второй карте (нагрузка, 25.H2).
    func pitchAllowed(performance: PerformanceMode) -> Bool {
        self != .cluster && performance == .full
    }

    /// Дома (тумблер «Дома»): на приборке — никогда; на плитке — только во
    /// «Вождении 3D» (48): там дома низкие (×0,45, ≤ 15 м) и при 45° дорогу не
    /// закрывают; полная высота при 58° закрывала (40J). Тёплый телефон гасит
    /// их видимостью (Drive3D.TileLevel), а не этим флагом: его смена —
    /// перезагрузка стиля.
    func houses(setting: Bool, drive3D: Bool = false) -> Bool {
        switch self {
        case .car: setting
        case .dashboard: setting && drive3D
        case .cluster: false
        }
    }

    /// Потолок наклона: плитка — `carPlayDashboard3DMaxPitch` во «Вождении 3D»
    /// (48, почему 45° — там же), иначе `carPlayDashboardMaxPitch` (40J);
    /// остальные — потолок движка.
    func maxPitch(drive3D: Bool) -> Double {
        guard self == .dashboard else { return AppConfig.engineMapPitchDegrees }
        return drive3D ? AppConfig.carPlayDashboard3DMaxPitch : AppConfig.carPlayDashboardMaxPitch
    }

    var maxPitch: Double { maxPitch(drive3D: false) }

    /// Малая частота кадров (как под полноэкранной тревогой, engineHotFPS):
    /// приборку читают боковым зрением, плавность там не видна, а кадры —
    /// это телефон, который греется.
    var lowFrameRate: Bool { self == .cluster }

    /// «Только дорога» всегда, не по скорости: на приборке окрестность не
    /// нужна и стоя.
    var alwaysDeclutter: Bool { self == .cluster }

    /// «Я» по высоте окна — своя доля; nil — по раскладке экрана машины
    /// (между баром и доком).
    var fixedMeY: Double? {
        switch self {
        case .car:       nil
        case .dashboard: AppConfig.carPlayDashboardMeY
        case .cluster:   AppConfig.carPlayClusterMeY
        }
    }
}
