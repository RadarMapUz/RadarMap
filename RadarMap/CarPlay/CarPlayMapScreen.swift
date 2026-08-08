//
//  CarPlayMapScreen.swift
//  RadarMap
//
//  Экран CarPlay: тёмная карта с камерами и маршрутом + приборная панель.
//
//  Раньше данные жили тремя плашками в разных углах — взгляд метался по экрану.
//  Теперь всё, что нужно постоянно (скорость, лимит, ближайшая камера, прибытие),
//  собрано в одну полосу внизу слева фиксированной высоты: карта не прыгает,
//  а глаз всегда знает, куда смотреть. Сверху — только события: манёвр слева
//  и алерт приближения справа.
//

import SwiftUI
import MapKit

/// Сигналы от кнопок шаблона CarPlay к карте (счётчики — представление
/// обрабатывает дельту и не хранит состояния шаблона).
@MainActor
@Observable
final class CarPlayMapModel {
    var recenterRequests = 0
    var zoomInRequests = 0
    var zoomOutRequests = 0
    /// «Схема» вместо карты: MKMapView выгружается ЦЕЛИКОМ. Картинка в машину
    /// стримится с телефона, так что тайлы и аннотации греют именно телефон —
    /// схема снимает самый дорогой рендер, оставляя те же предупреждения.
    var showsSketch: Bool
    /// Режим выбран рукой водителя: автоматика жары его больше не трогает
    /// (та же иерархия, что у кнопки тишины: человек старше автоматики).
    @ObservationIgnored var userChoseView: Bool

    init() {
        showsSketch = Storage.bool(.carPlayShowsSketch)
        userChoseView = Storage.bool(.carPlayViewChosen)
        #if DEBUG
        // Скриншот-хук: -carplayPreview -carplaySketch открывает сразу схему.
        if ProcessInfo.processInfo.arguments.contains("-carplaySketch") {
            showsSketch = true
            userChoseView = true
        }
        #endif
    }

    /// Тумблер с кнопки шаблона: выбор запоминается между поездками.
    func toggleView() {
        showsSketch.toggle()
        userChoseView = true
        Storage.set(showsSketch, for: .carPlayShowsSketch)
        Storage.set(true, for: .carPlayViewChosen)
    }

    /// Автоматика жары: телефон греется — включаем схему, остыл — возвращаем
    /// карту. Только пока водитель не выбрал режим сам.
    func autoSwitch(for mode: PerformanceMode) {
        guard !userChoseView else { return }
        showsSketch = mode != .full
    }
}

struct CarPlayMapScreen: View {
    @Environment(AppEnvironment.self) private var env
    let model: CarPlayMapModel

    var body: some View {
        ZStack {
            if model.showsSketch {
                CarPlaySketchView()
            } else {
                CarPlayMapView(model: model,
                               repository: env.cameras,
                               route: env.route,
                               location: env.location,
                               speedLimits: env.speedLimits,
                               thermal: env.thermal)
                    .ignoresSafeArea()
            }

            // HUD — отдельная вью-изолятор (см. CarPlayOverlay): пер-тиковые
            // скорость/дистанции читаются там, и тик пересобирает маленький
            // HUD, а не это дерево с UIViewRepresentable карты.
            CarPlayOverlay()
        }
        // Жара: схема сама, пока водитель не выбрал режим кнопкой. Проверка и
        // на подключении тоже — в машину можно сесть с уже горячим телефоном.
        .onAppear { model.autoSwitch(for: env.thermal.mode) }
        .onChange(of: env.thermal.mode) { _, mode in
            withAnimation(.easeInOut(duration: 0.3)) { model.autoSwitch(for: mode) }
        }
    }
}
