//
//  MapScreen+Controls.swift
//  RadarMap
//
//  Главный экран: правая колонка кнопок карты, слои и вид.
//

import SwiftUI
import MapKit
import CoreLocation
import UIKit

extension MapScreen {

    // MARK: - Колонка навигации (компас, локация, зум)

    /// Две кнопки — и обе живут постоянно, не прячась по таймауту.
    ///
    /// Раньше колонка пряталась целиком через 5 секунд бездействия в поездке, и
    /// вместе с ней исчезала кнопка «Радар здесь!» — то есть единственный способ
    /// отметить треногу пропадал ровно тогда, когда мимо треноги едешь. Прятать
    /// нужно хром (легенду, быстрые цели, бар действий), а не органы управления.
    var controlColumn: some View {
        VStack(spacing: 12) {
            if mode.keepsMapToolsInMenu {
                tripControls
            } else {
                idleControls
            }
            // Зум — щипком, как в Apple Maps: кнопки только занимали место.
        }
        .motionAnimation(Motion.standard, value: mode.keepsMapToolsInMenu)
    }

    /// В поездке — три кнопки: «…», ориентация, звук. Слои, 3D, «весь
    /// маршрут» и разделы приложения — плитками «Ещё». Семь кругов столбиком закрывали
    /// треть карты справа, а на ходу из них нажимают звук и «к машине»
    /// (docs/plan_drive_ux_2026-10-07.md, п. 4). Компас — только когда карту
    /// повернули руками.
    ///
    /// Порядок — ТОТ ЖЕ, что в покое (33H3, 28.10): сверху «…» (с этапа 45 —
    /// и в покое), потом «к себе», то, что по делу, и звук
    /// внизу. Раньше звук в поездке прыгал наверх, а «к себе» — на второе
    /// место с третьего: рука искала кнопку там, где её только что не было.
    @ViewBuilder var tripControls: some View {
        let extras = TripScreenLayout.columnExtras(
            slots: columnSlots, fixed: AppConfig.mapColumnFixedButtons,
            candidates: (map.isRotated ? [(.compass, 1)] : []) + trafficScoreCandidate)
        tripMenu
        orientationControl
        if extras.contains(.compass) {
            MapCompassButton(map: map)
        }
        if extras.contains(.trafficScore) { trafficScoreChip }
        MapMuteButton()
    }

    /// «…» поездки — на месте «Слоёв»: плитки «Ещё» над нижними панелями
    /// (этап 45, вариант A) вместо системного меню из четырнадцати строк.
    ///
    /// Поиск, «Итоги», «Добавить камеру» и Настройки живут в нижнем баре, а
    /// бар показывается только в покое: стоило поездке начаться — и с
    /// главного экрана они пропадали все разом. Адрес ищут и список камер
    /// смотрят именно в дороге, поэтому плитки, а не пять кнопок в колонке:
    /// в колонке живёт то, чем управляют на ходу (plan_app_ui.md, У6).
    var tripMenu: some View {
        MapMoreButton(isOpen: popover == .tripMenu) { send(.toggle(.tripMenu)) }
            .onDisappear {
                // Ушла кнопка — уходят и плитки, и панель «Карта» у неё.
                send(.dismissed(.tripMenu))
                send(.dismissed(.layers))
            }
            .transition(.scale.combined(with: .opacity))
    }

    /// Покой — ТРИ постоянные кнопки (этап 31, 26.10): «…», «к себе» и звук.
    /// Шесть кругов (слои, 3D, к себе, +, −, звук) накрывали камеры у правого
    /// края. Панель «Карта» — плитка «…» (этап 45), в ней же
    /// «Объёмный вид» (переключают раз в месяц, а не каждую поездку);
    /// «к себе» нужна после каждого сдвига карты; звук — то, что
    /// выключают на ходу. Масштаб — щипком, кнопки +/− включаются в панели
    /// «Карта» → «Масштаб» (по умолчанию выключены). По делу появляются
    /// компас (карта повёрнута) и «весь маршрут» (маршрут построен).
    @ViewBuilder var idleControls: some View {
        // Остальное — по важности, пока есть место до нижних панелей
        // (TripScreenLayout.columnExtras).
        let extras = TripScreenLayout.columnExtras(
            slots: columnSlots, fixed: AppConfig.mapColumnFixedButtons,
            candidates: (map.isRotated ? [(.compass, 1)] : [])
                + trafficScoreCandidate
                + (env.route.isActive ? [(.overview, 1)] : [])
                + (env.settings.mapZoomButtons ? [(.zoom, 2)] : []))
        // «…» — первой в колонке, на месте прежних «Слоёв» и там же, где в
        // поездке (этап 45): те же плитки «Ещё», на стоянке 3 × 3; слои
        // карты — плитка «Карта», панель встаёт у этого же круга.
        tripMenu
        // Вид карты, как у навигаторов: 2D/3D, «моё местоположение»
        // (1-й тап — к машине, 2-й — по ходу движения), компас — только
        // когда карта повёрнута, звук.
        orientationControl
        if extras.contains(.compass) {
            MapCompassButton(map: map)
        }
        if extras.contains(.trafficScore) { trafficScoreChip }
        // «Весь маршрут» — пока он есть: посмотреть его целиком до старта.
        if extras.contains(.overview), env.route.isActive, let polyline = env.route.polyline {
            CircleControl(systemName: "point.topleft.down.to.point.bottomright.curvepath",
                          tint: Theme.textPrimary,
                          accessibilityLabel: "Весь маршрут") {
                map.showRouteOverview(rect: polyline.boundingMapRect)
            }
            .transition(.scale.combined(with: .opacity))
        }
        if extras.contains(.zoom) {
            MapZoomButtons(map: map)
                .transition(.scale.combined(with: .opacity))
        }
        MapMuteButton()
        // Жёлтой кнопки «Радар здесь» здесь БОЛЬШЕ НЕТ: в поездке их было
        // две с разным поведением, осталась та, что в панели поездки
        // (отправка одним тапом с последующим уточнением).
    }

    /// Балл пробок города (33H, как «9» у Яндекса): только при включённых
    /// пробках и когда балл есть; касание — лист «Пробки» с легендой.
    var trafficScoreCandidate: [(TripScreenLayout.ColumnExtra, Int)] {
        env.traffic.isShown && env.traffic.cityScore != nil ? [(.trafficScore, 1)] : []
    }

    @ViewBuilder var trafficScoreChip: some View {
        if let score = env.traffic.cityScore {
            TrafficScoreChip(score: score) { map.showTrafficLegend = true }
                .transition(.scale.combined(with: .opacity))
        }
    }

    /// Просвет для колонки справа: от нижнего края верхних панелей до
    /// верхнего края нижних (обе кромки уже мерятся для схемы). Пишет число
    /// мест только при его смене — см. `columnSlots`.
    func updateColumnSlots() {
        let measured = topPanelEdge > 0 && bottomPanelEdge > 0
        let room = measured ? bottomPanelEdge - topPanelEdge : nil
        let slots = TripScreenLayout.columnSlots(room: room)
        if slots != columnSlots { columnSlots = slots }
        // Просвет целиком — для карточки «Карта по пути» (CorridorOfferPlacement).
        map.setColumnRoom(room)
    }

    var orientationControl: some View {
        MapOrientationControl(orientation: map.orientation) {
            map.cycleOrientation(coordinate: env.location.currentCoordinate,
                                 course: env.location.currentCourse,
                                 inTrip: env.location.isTripActive)
        }
    }

    /// Привязка к настройке без восьми одинаковых `Binding(get:set:)`.
    func setting<Value>(_ keyPath: ReferenceWritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        let settings = env.settings
        return Binding(get: { settings[keyPath: keyPath] },
                       set: { settings[keyPath: keyPath] = $0 })
    }
}
