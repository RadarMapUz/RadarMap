//
//  CarPlayMapScreen.swift
//  RadarMap
//
//  Экран CarPlay: тёмная карта с камерами и маршрутом + приборная панель.
//
//  Всё, что нужно постоянно (скорость, лимит, ближайшая камера, прибытие),
//  собрано внизу слева: карта не прыгает, а глаз всегда знает, куда
//  смотреть. Сверху — только манёвр.
//
//  Режима «Схема» больше нет (11.10, слово владельца: «не актуально, там
//  ничего не работает»). Экран машины — одна карта: движок или, при
//  выключенном движке, карта Apple.
//

import SwiftUI
import MapKit
import os

/// Сигналы от кнопок шаблона CarPlay к карте (счётчики — представление
/// обрабатывает дельту и не хранит состояния шаблона).
@MainActor
@Observable
final class CarPlayMapModel {

    /// Снос — БЕЗ прыжка на актор, и это не стиль, а обход живого бага рантайма.
    ///
    /// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor синтезирует isolated deinit
    /// каждому @MainActor-классу, даже когда своего deinit нет. Такой deinit
    /// уходит в swift_task_deinitOnExecutor, тот в синхронном кадре главного
    /// потока (текущей Task нет) заводит TaskLocal::StopLookupScope, а
    /// MarkerItem::create в рантайме iOS 26 берёт память у task-аллокатора
    /// БЕЗУСЛОВНО — при task == nullptr это статический слэб внутри
    /// libswift_Concurrency. Item::destroy потом зовёт free() по этому
    /// указателю: «pointer being freed was not allocated» → SIGABRT.
    ///
    /// Условия сходятся ровно там, где SwiftUI сносит вью с @State-моделью
    /// внутри GraphHost.runTransaction: там жива task-local привязка. В ветке
    /// main рантайма баг уже исправлен; до выхода такой iOS помогает одно —
    /// не синтезировать isolated deinit вовсе.
    nonisolated deinit {}

    var recenterRequests = 0
    var zoomInRequests = 0
    var zoomOutRequests = 0
    /// Карта на движке: панорама от шаблона (счётчик и сдвиг содержимого в
    /// точках), «+/−» при слежении — сдвиг автозума вдвое за нажатие (как на
    /// телефоне), «+/−» на свободной карте — шаг уровня.
    /// Сумма всех сдвигов панорамы (точки экрана) — карта берёт разницу.
    var panTotal = CGSize.zero
    var zoomBias = 0.0
    var zoomCommand = 0
    var zoomDelta = 0.0
    /// День или ночь на экране машины — ОДНО значение на карту и HUD.
    /// Раньше HUD брал тему окна машины, а подложка — солнце, и первый кадр
    /// всегда был тёмным. Ставит делегат сцены ещё до первого кадра.
    var isDaylight = false
    /// Тема машины (датчик света, фары): в «Авто» она старше солнца — она
    /// знает про тоннель и пасмурный вечер, а таблица восходов не знает.
    @ObservationIgnored var carIsDark: Bool?
    /// Манёвр показывает сама машина (навигационная сессия): свой баннер
    /// манёвра тогда не рисуем — два одинаковых поворота на одном экране.
    var hasSystemGuidance = false
    /// Экран машины показывает нас. В фоне (на экране другое приложение или
    /// приборная панель) карта на движке выгружается: картинку никто не видит,
    /// а рисует и греется телефон. Ставит делегат сцены.
    var isOnScreen = true
    /// Едет ли карта за машиной. Пишет координатор карты (система сама снимает
    /// слежение, как только водитель тронул карту пальцем или крутилкой),
    /// читает значок кнопки «к себе»: залитый — следим, контурный — стоим.
    var isFollowing = true
    /// Последний регион карты Apple (фолбэк при выключенном движке). Карта
    /// выгружается, пока экран машины занят другим приложением, и при возврате
    /// создавалась бы заново в умолчании, теряя масштаб, выставленный руками.
    /// Держать её живой ради этого нельзя — невидимая, она тянет тайлы.
    /// Поэтому помним не карту, а её регион — четыре числа.
    @ObservationIgnored var lastRegion: MKCoordinateRegion?

    /// Рисует ли карту движок (наша карта), а не MapKit. Та же настройка
    /// подложки, что на телефоне: выключатель один на оба экрана.
    static func usesEngine(_ settings: AppSettings) -> Bool {
        #if canImport(MapLibre)
        settings.mapBase == .engine
        #else
        false
        #endif
    }

    /// Сдвиг карты на столько точек экрана (содержимое едет за пальцем).
    func pan(by translation: CGSize) {
        guard translation != .zero else { return }
        panTotal = CGSize(width: panTotal.width + translation.width,
                          height: panTotal.height + translation.height)
        if isFollowing { isFollowing = false }
    }

    /// «+ / −». При слежении меняется автозум (масштаб по скорости остаётся,
    /// сдвигается его уровень), на свободной карте — сам вид.
    func zoom(in zoomIn: Bool, engine: Bool) {
        guard engine else {
            if zoomIn { zoomInRequests += 1 } else { zoomOutRequests += 1 }
            return
        }
        if isFollowing {
            zoomBias = min(AppConfig.carPlayZoomBiasLimit,
                           max(-AppConfig.carPlayZoomBiasLimit, zoomBias + (zoomIn ? 1 : -1)))
        } else {
            zoomDelta = zoomIn ? 1 : -1
            zoomCommand &+= 1
        }
    }

    /// «К себе»: карта снова едет за машиной.
    func recenter() {
        recenterRequests += 1
        if !isFollowing { isFollowing = true }
    }

    /// Пересчитать день/ночь. Ручной выбор старше всего; в «Авто» — машина,
    /// а без её ответа — солнце в точке водителя.
    func refreshDaylight(appearance: MapAppearance, coordinate: CLLocationCoordinate2D?) {
        let day: Bool
        if appearance == .auto, let carIsDark {
            day = !carIsDark
        } else {
            day = appearance.isDaylight(at: coordinate)
        }
        if day != isDaylight { isDaylight = day }
    }
}

struct CarPlayMapScreen: View {
    @Environment(AppEnvironment.self) private var env
    let model: CarPlayMapModel

    var body: some View {
        ZStack {
            if CarPlayMapModel.usesEngine(env.settings) {
                if model.isOnScreen { engineMap } else { Theme.background.ignoresSafeArea() }
            } else {
                CarPlayMapView(model: model,
                               repository: env.cameras,
                               route: env.route,
                               location: env.location,
                               speedLimits: env.speedLimits,
                               thermal: env.thermal,
                               filter: env.settings.filter,
                               showsTraffic: env.settings.mapTraffic,
                               isDaylight: model.isDaylight)
                    .ignoresSafeArea()
            }

            // HUD — отдельная вью-изолятор (см. CarPlayOverlay): пер-тиковые
            // скорость/дистанции читаются там, и тик пересобирает маленький
            // HUD, а не это дерево с UIViewRepresentable карты.
            CarPlayOverlay(showsManeuver: !model.hasSystemGuidance)

            // «Радар ещё стоял?» после реального проезда: наблюдение — в
            // MobileCameraService на каждом фиксе (не во вью), сам вопрос в
            // машине — шаблоном (CarPlayAlerts), а не рисованием.
        }
        // Тема HUD — та же, что у подложки, из одной точки (model.isDaylight):
        // токены Theme адаптивные и иначе брали бы тему окна машины.
        .environment(\.colorScheme, model.isDaylight ? .light : .dark)
        // Улика для «окно машины застыло» (11.10: кнопки шаблона жили,
        // картинка стояла). Эта строка пишется, только когда SwiftUI
        // действительно пересобрал экран машины; делегат рядом пишет
        // «сцена машины: background/foreground». Есть его строка, а этой
        // нет — сцена сменилась, а дерево интерфейса стоит.
        .onChange(of: model.isOnScreen) { _, shown in
            Log.carplay.notice("экран машины перерисован: на экране \(shown, privacy: .public)")
        }
        // База камер докодировалась/обновилась — пересчитать «что рядом» СРАЗУ.
        // Раньше эта подписка жила только в телефонном MapScreen: при холодном
        // запуске из машины (телефон в кармане) первый фикс приходил раньше
        // базы, машина стояла на месте, нового фикса distanceFilter не давал —
        // и док показывал «Чисто» до первого движения.
        .onChange(of: env.cameras.revision) { env.location.refreshMonitoring() }
        // День/ночь: раз в минуту, вне body. Чтение координаты внутри .task
        // не отслеживается SwiftUI, а минутный шаг на границе восхода —
        // незаметная цена против пересборки дерева карты каждым фиксом. Тема
        // машины приходит сразу (contentStyleDidChange в делегате).
        .task {
            while !Task.isCancelled {
                model.refreshDaylight(appearance: env.settings.mapAppearance,
                                      coordinate: env.location.currentCoordinate)
                try? await Task.sleep(for: .seconds(60))
            }
        }
        // Настройку водитель мог сменить на телефоне посреди поездки — минуты
        // не ждём.
        .onChange(of: env.settings.mapAppearance) { _, appearance in
            model.refreshDaylight(appearance: appearance,
                                  coordinate: env.location.currentCoordinate)
        }
    }

    @ViewBuilder private var engineMap: some View {
        #if canImport(MapLibre)
        CarPlayEngineLayer(model: model)
        #endif
    }
}
