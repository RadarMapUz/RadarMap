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

    /// В поездке — три кнопки: звук, ориентация, «…». Слои, 3D, «весь
    /// маршрут» и разделы приложения — пунктами меню. Семь кругов столбиком закрывали
    /// треть карты справа, а на ходу из них нажимают звук и «к машине»
    /// (docs/plan_drive_ux_2026-10-07.md, п. 4). Компас — только когда карту
    /// повернули руками.
    @ViewBuilder var tripControls: some View {
        let extras = TripScreenLayout.columnExtras(
            slots: columnSlots, fixed: AppConfig.mapColumnFixedButtons,
            candidates: map.isRotated ? [(.compass, 1)] : [])
        MapMuteButton()
        orientationControl
        if extras.contains(.compass) {
            MapCompassButton(map: map)
        }
        // Семь функций, до которых в поездке было не добраться.
        //
        // Поиск, «Рядом», «Итоги», «Добавить камеру» и Настройки живут в
        // нижнем баре, а бар показывается только в покое: стоило поездке
        // начаться — и с главного экрана они пропадали все разом. Причина
        // верная (за рулём экран отдан карте), следствие нет: адрес ищут и
        // список камер смотрят именно в дороге, а единственным способом
        // было остановить запись поездки — то есть испортить её же данные.
        //
        // Меню, а не пять кнопок: в колонке живёт то, чем управляют на
        // ходу, остальное открывается одним тапом и одним взглядом
        // (plan_app_ui.md, У6).
        Menu {
            Section { mapViewItems }
            Section { tripActionItems }
        } label: {
            CircleControlFace(systemName: "ellipsis")
        }
        .accessibilityLabel(Text("Ещё"))
        .transition(.scale.combined(with: .opacity))
    }

    /// Покой: как было — слои, 3D, ориентация, компас, весь маршрут, масштаб, звук.
    @ViewBuilder var idleControls: some View {
        // Обязательные — слои, «к себе» и звук (слои в покое — единственный
        // вход в смену подложки); остальное по важности, пока есть место до
        // нижних панелей (TripScreenLayout.columnExtras).
        let extras = TripScreenLayout.columnExtras(
            slots: columnSlots, fixed: AppConfig.mapColumnFixedButtons,
            candidates: (map.isRotated ? [(.compass, 1)] : [])
                + (env.route.isActive ? [(.overview, 1)] : [])
                + (DesignLab.home == .c ? [] : [(.threeD, 1)])
                + (env.settings.mapZoomButtons && DesignLab.home != .c ? [(.zoom, 2)] : []))
        // Слои карты — первой в колонке.
        //
        // Подложка лежала в десятом разделе настроек и включалась только
        // после старта поездки; пробки и места жили в отдельной панели,
        // которой в поездке не бывало вовсе. Теперь это одна панель; в
        // поездке та же панель — подменю «…» (mapLayersMenu).
        //
        // Сама панель «Карта» — в слое меню над экраном (MapScreen+Popovers):
        // касание мимо неё закрывает её, не задевая карту. Ушла кнопка
        // (старт поездки, прибытие, режим добавления камеры) — уходит и панель.
        MapLayersButton(isOpen: popover == .layers) {
            send(.toggle(.layers))
        }
        .onDisappear { send(.dismissed(.layers)) }
        // Вид карты, как у навигаторов: 2D/3D, «моё местоположение»
        // (1-й тап — к машине, 2-й — по ходу движения), компас — только
        // когда карта повёрнута, звук.
        if extras.contains(.threeD) {
            Map3DToggle(map: map)
        }
        orientationControl
        if extras.contains(.compass) {
            MapCompassButton(map: map)
        }
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

    /// Вид карты в меню «…» поездки: то, что в покое стоит кнопками колонки.
    @ViewBuilder var mapViewItems: some View {
        mapLayersMenu
        Toggle(isOn: Binding(get: { env.settings.map3D },
                             set: { on in
                                 env.settings.map3D = on
                                 map.prefers3D = on
                             })) {
            Label("Объёмный вид", systemImage: "view.3d")
        }
        if env.route.isActive, let polyline = env.route.polyline {
            Button {
                map.showRouteOverview(rect: polyline.boundingMapRect)
            } label: {
                Label("Весь маршрут", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
        }
    }

    /// Слои подменю: те же переключатели и те же значки, что в панели
    /// MapLayersPanel.
    var mapLayersMenu: some View {
        Menu {
            Toggle(isOn: setting(\.trafficShown)) {
                Label("Пробки", systemImage: Icon.trafficLayer)
            }
            Toggle(isOn: setting(\.mapPlaces)) {
                Label("Места", systemImage: Icon.placesLayer)
            }
            Toggle(isOn: setting(\.mapHouses)) {
                Label("Дома", systemImage: Icon.buildingsLayer)
            }
            Toggle(isOn: setting(\.mapSidewalks)) {
                Label("Тротуары", systemImage: Icon.sidewalksLayer)
            }
        } label: {
            Label("Слои карты", systemImage: "square.3.layers.3d")
        }
    }
}
