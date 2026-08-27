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
    /// Состояние схемы. Живёт ЗДЕСЬ, а не во вью, потому что осмотр в машине
    /// приходит от шаблона CarPlay (CPMapTemplateDelegate), а до вью делегату
    /// не дотянуться. Одна модель на оба входа — иначе правило возврата
    /// разошлось бы между телефоном и машиной.
    let sketch = SketchState()

    var recenterRequests = 0
    var zoomInRequests = 0
    var zoomOutRequests = 0
    /// Едет ли карта за машиной. Пишет координатор карты (система сама снимает
    /// слежение, как только водитель тронул карту пальцем или крутилкой),
    /// читает значок кнопки «к себе»: залитый — следим, контурный — стоим.
    var isFollowing = true
    /// «Схема» вместо карты: MKMapView выгружается ЦЕЛИКОМ. Картинка в машину
    /// стримится с телефона, так что тайлы и аннотации греют именно телефон —
    /// схема снимает самый дорогой рендер, оставляя те же предупреждения.
    var showsSketch: Bool {
        didSet { if showsSketch != oldValue { onViewModeChanged?() } }
    }

    /// Режим сменился — пересобрать кнопки шаблона.
    ///
    /// Кнопки CarPlay живут вне цикла обновления SwiftUI, и обновляет их только
    /// пересборка шаблона. Наблюдения для этого мало: подписка одноразовая и
    /// восстанавливается асинхронно, а режим меняет не только кнопка, но и
    /// автоматика жары — из вью, до которой делегату не дотянуться. Без крючка
    /// содержимое уходило в схему, а кнопки оставались от карты.
    @ObservationIgnored var onViewModeChanged: (() -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue,
                                               current: onViewModeChanged, "onViewModeChanged") }
    }
    /// Режим выбран рукой водителя: автоматика жары его больше не трогает
    /// (та же иерархия, что у кнопки тишины: человек старше автоматики).
    @ObservationIgnored var userChoseView: Bool

    /// Последний регион карты. Схема выгружает MKMapView целиком — в этом и
    /// смысл режима, — но при возврате карта создавалась заново и вставала в
    /// умолчание, теряя масштаб, который водитель выставил руками. Держать
    /// карту живой ради этого нельзя: невидимая, она продолжает тянуть тайлы,
    /// то есть ровно то, от чего схема и спасает. Поэтому помним не карту,
    /// а её регион — четыре числа.
    @ObservationIgnored var lastRegion: MKCoordinateRegion?

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
    /// День/ночь для подложки карты. @State, а не computed: чтение
    /// currentCoordinate в body пересобирало бы всё дерево с картой на каждый
    /// GPS-тик, а ответ солнца меняется дважды в сутки.
    @State private var isDaylight = false

    var body: some View {
        ZStack {
            if model.showsSketch {
                CarPlaySketchView(sketch: model.sketch)
            } else {
                CarPlayMapView(model: model,
                               repository: env.cameras,
                               route: env.route,
                               location: env.location,
                               speedLimits: env.speedLimits,
                               thermal: env.thermal,
                               filter: env.settings.filter,
                               showsTraffic: env.settings.mapTraffic,
                               isDaylight: isDaylight)
                    .ignoresSafeArea()
            }

            // HUD — отдельная вью-изолятор (см. CarPlayOverlay): пер-тиковые
            // скорость/дистанции читаются там, и тик пересобирает маленький
            // HUD, а не это дерево с UIViewRepresentable карты.
            CarPlayOverlay()

            // «Радар ещё стоял?» после реального проезда. Раньше этот вопрос
            // жил только в телефонном MapScreen, а при подключённом CarPlay
            // телефонная сцена уступает место экрану передачи — то есть в
            // машине водитель краудсорс ТОЛЬКО потреблял и ничего не возвращал.
            // Драйвер тот же, что на телефоне; сам вопрос показывает
            // CarPlayOverlay.
            MobilePassDriver()
        }
        // Жара: схема сама, пока водитель не выбрал режим кнопкой. Проверка и
        // на подключении тоже — в машину можно сесть с уже горячим телефоном.
        .onAppear { model.autoSwitch(for: env.thermal.mode) }
        .onChange(of: env.thermal.mode) { _, mode in
            withAnimation(.easeInOut(duration: 0.3)) { model.autoSwitch(for: mode) }
        }
        // База камер докодировалась/обновилась — пересчитать «что рядом» СРАЗУ.
        // Раньше эта подписка жила только в телефонном MapScreen: при холодном
        // запуске из машины (телефон в кармане) первый фикс приходил раньше
        // базы, машина стояла на месте, нового фикса distanceFilter не давал —
        // и док показывал «Чисто» до первого движения.
        .onChange(of: env.cameras.revision) { env.location.refreshMonitoring() }
        // День/ночь подложки: раз в минуту, вне body. Чтение координаты внутри
        // .task не отслеживается SwiftUI, а минутный шаг на границе восхода —
        // незаметная цена против пересборки дерева карты каждым фиксом.
        // Пока экран машины жив, одна арифметика NOAA в минуту — копейки.
        .task {
            while !Task.isCancelled {
                isDaylight = Self.daylight(appearance: env.settings.mapAppearance,
                                           coordinate: env.location.currentCoordinate)
                try? await Task.sleep(for: .seconds(60))
            }
        }
        // Настройку водитель мог сменить на телефоне посреди поездки — минуты
        // не ждём.
        .onChange(of: env.settings.mapAppearance) { _, appearance in
            isDaylight = Self.daylight(appearance: appearance,
                                       coordinate: env.location.currentCoordinate)
        }
    }

    /// Светлая подложка карты — по той же настройке, что на телефоне, и по
    /// тому же солнцу. Правило «Авто» считает восход и закат в точке водителя,
    /// а не по часам: в декабре в 18:30 уже темно, и белая карта слепит.
    private static func daylight(appearance: MapAppearance,
                                 coordinate: CLLocationCoordinate2D?) -> Bool {
        // Решение переехало в MapAppearance: его спрашивает и схема приборки,
        // а две копии одного правила разошлись бы молча.
        appearance.isDaylight(at: coordinate)
    }
}
