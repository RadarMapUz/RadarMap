//
//  MapScreen.swift
//  RadarMap
//
//  Главный экран: тёмная карта с камерами, HUD, контролы, добавление, поиск, список, статистика.
//

import SwiftUI
import MapKit
import CoreLocation
import UIKit

struct MapScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var map = MapState()
    @State private var dismissedApproachID: Int?
    @State private var showRouteCameras = false
    /// «Мои места» из нижнего бара: Дом, Работа, недавние — маршрут в один тап.
    @State private var showMyPlaces = false
    /// Экранная модель своей схемы. Живёт всегда, а считается только когда
    /// схема действительно на экране: пустая модель не стоит ничего.
    /// Поля вида (отступы панелей и якорь машины) — их читает наша карта.
    /// Имя историческое: модель заводилась под самодельную схему, а осталась
    /// от неё только геометрия вида, которой пользуется движок.
    @State private var frame = MapFrameState()
    /// Нижняя кромка верхних панелей и верхняя кромка нижних, в пунктах окна.
    /// Меряют сами панели; схема переводит их в доли своей высоты.
    @State private var topPanelEdge: CGFloat = 0
    @State private var bottomPanelEdge: CGFloat = 0
    /// Сколько кнопок помещается в колонку справа (TripScreenLayout.columnSlots).
    /// Отдельно от кромок и только при смене: кромки body не читает, а это
    /// число — читает, и писать его на каждый пиксель высоты панели значило
    /// бы пересобирать весь экран с картой (Perf.mapBody).
    @State private var columnSlots: Int?
    /// Разовая подсказка о жесте (см. OneTimeHints): максимум одна за запуск.
    @State private var activeHint: OneTimeHints.Hint?
    @State private var hintConsumedThisLaunch = false
    /// «Батарея садится — погасите экран»: поездка началась, заряд тает, а
    /// зарядки нет.
    @State private var showBatterySaverHint = false
    /// Быстрые тумблеры оповещений (тап по HUD).
    @State private var showQuickToggles = false
    /// Итог только что завершённой поездки («Поездка сохранена») и деталка из него.
    @State private var tripEndRecord: TripRecord?
    @State private var tripEndDetail: TripRecord?
    @Environment(\.scenePhase) private var scenePhase
    /// Пикер типа отметки (радар/тренога/пост/ДТП) для выбранной точки.
    @State private var reportPoint: MapPoint?
    /// Область карты для системных контролов MapKit. Своих в ней не осталось
    /// (компас убран), но scope нужен `Map(scope:)`.

    /// Что нужно водителю прямо сейчас: правила видимости — в MapMode,
    /// а не россыпью условий по вёрстке (см. MapMode.swift).
    private var mode: MapMode {
        MapMode.current(isTripActive: env.location.isTripActive, hasRoute: env.route.isActive)
    }

    var body: some View {
        @Bindable var map = map
        // Событие, а не интервал: у пересборки тела нет длительности, которую
        // мы могли бы измерить изнутри, — ценно её КОЛИЧЕСТВО. Здесь висит
        // карта с двумя сотнями маркеров, и каждая лишняя пересборка стоит
        // дороже всего, что мы считаем на тике. На дорожке приборов частота
        // этих точек и есть ответ, нужна ли изоляция слоя карты.
        //
        // `let _ =` — не стиль, а единственная форма, которую пропускает
        // ViewBuilder: голый вызов в его блоке — это значение типа `()`, а он
        // требует `View`. Тем же приёмом пользуется `Self._printChanges()`.
        let _ = Perf.event(Perf.Name.mapBody)

        // Один расчёт на проход body, а не три. Внутри «Авто» лежит NOAA-счёт
        // восхода: он дешёвый, но вызывать его трижды за кадр незачем.
        let scheme = mapColorScheme

        ZStack {
            // Тема только у карты: интерфейс остаётся тёмным «радар-детектором»,
            // а подложка днём может быть светлой (тёмная на солнце бликует).
            baseLayer(scheme: scheme)

            // Затемнение под статус-баром: часы и батарея не тонут в карте.
            VStack(spacing: 0) {
                LinearGradient(colors: [Theme.background.opacity(0.7), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 110)
                Spacer()
            }
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)

            if map.isAddingCamera { crosshair }

            // Всё, что читает тик GPS, — только пока экран на виду.
            //
            // Профиль свёрнутого приложения в поездке (Time Profiler, 11.10)
            // показал главный поток, занятый SwiftUI: AttributeGraph
            // пересчитывал HUD скорости, панель поездки и плашки на каждом
            // фиксе, хотя экран не видел никто, — ~9 % ядра часами, в кармане
            // и в держателе на солнце. Подложка в фоне уже выгружается
            // (baseLayer); здесь — живые цифры поверх неё. Вернулись — слои
            // собираются заново первым же тиком; листы и маршрут живут не тут.
            if scenePhase != .background {
                // Панели знают, что под ними светлая карта: днём их фон плотнее,
                // иначе белые цифры на солнце тонут в стекле.
                topLayer
                    .environment(\.onLightMap, scheme == .light)
                bottomLayer
                    .environment(\.onLightMap, scheme == .light)

                // Превышение у камеры: свечение по краям. Отдельная вью: условие
                // читает скорость и дистанцию, меняющиеся каждый тик GPS, — в body
                // MapScreen это чтение пересобирало весь экран с картой ежесекундно.
                OverspeedVignetteGate()

                // Следование за GPS: единственный подписчик locationTick.
                LocationFollowDriver(map: map, drivesAppleCamera: false)
            }
        }
        .task {
            map.configure(env.cameras, speedLimits: env.speedLimits, thermal: env.thermal,
                          hotspots: env.hotspots)
            map.filter = env.settings.filter
            // 3D в поездке переключается из меню «…», где кнопки Map3DToggle
            // нет — её onAppear мог и не случиться (старт сразу в поездке).
            map.prefers3D = env.settings.map3D
            // Если карта уже отдала регион до конфигурации (статичный старт без геопозиции) —
            // пересчитываем принудительно, иначе аннотации не появятся до первого движения карты.
            map.invalidateVisible()
            if let coordinate = env.location.currentCoordinate {
                map.snapToUserOnce(coordinate)   // геопозиция уже известна — сразу к своим камерам
            }
            #if DEBUG
            openScreenFromLaunchArguments()
            #endif
            // Подсказка о жесте — после того как карта обжилась: чип поверх
            // стартовой анимации читается как сбой, а не как помощь.
            Task {
                await Task.pause(seconds: 3)
                maybeShowHint()
                // Каталог областей — маленький подписанный файл; нужен, только
                // пока на предложение скачать карту не ответили.
                if !Storage.bool(.offlineOfferAnswered), env.offlineMaps.catalog == nil,
                   !env.network.isExpensive {
                    await env.offlineMaps.refreshCatalog()
                }
            }
        }
        .onChange(of: env.settings.filter) { _, newValue in
            map.filter = newValue
            map.invalidateVisible()
        }
        .onChange(of: env.cameras.revision) { _, _ in
            // Любое изменение данных (загрузка базы, свои камеры, скрытие) —
            // одна точка обновления карты и region-мониторинга.
            map.invalidateVisible()
            env.location.refreshMonitoring()
        }
        .onChange(of: env.speedLimits.indexRevision) { _, _ in
            // База лимитов приехала позже первого слоя — пересобираем маркеры,
            // чтобы появились мини-знаки «60».
            map.invalidateVisible()
        }
        .sheet(item: $map.selectedCamera) { camera in
            CameraDetailSheet(camera: camera,
                              onRoute: !env.location.hasLocation ? nil : {
                                  buildRoute(to: camera.coordinate, name: camera.displayTitle)
                              })
        }
        .sheet(isPresented: $map.showNearbySheet) {
            NearbyCamerasSheet(onSelect: { map.focus(on: $0) })
        }
        .sheet(isPresented: $map.showSearch) {
            // Без геопозиции кнопки маршрута прячем, как в соседних шитах:
            // мёртвая кнопка, молча закрывающая поиск, хуже её отсутствия.
            // Выбранное место — точкой на карте с её панелью («Маршрут сюда»,
            // «Радар здесь»): раньше карта только сдвигалась, и что выбрано,
            // оставалось угадывать.
            SearchView(onSelect: { coordinate, title in
                           map.move(to: coordinate)
                           withMotion(.spring(duration: 0.3)) {
                               map.pressedPoint = MapPoint(coordinate: coordinate, title: title)
                           }
                       },
                       onRoute: !env.location.hasLocation ? nil
                           : { coord, name in buildRoute(to: coord, name: name) },
                       onAddStop: !env.location.hasLocation || !env.route.isActive ? nil
                           : { coord, name in addStop(coord, name: name) })
        }
        .sheet(isPresented: $showRouteCameras) {
            RouteCamerasSheet(onSelect: { map.focus(on: $0) })
        }
        .sheet(isPresented: $showMyPlaces) {
            // Те же два пути, что у поиска: с геопозицией — маршрут, без неё —
            // точка на карте с её панелью, а не мёртвая строка.
            MyPlacesSheet(onRoute: !env.location.hasLocation ? nil
                              : { coord, name in buildRoute(to: coord, name: name) },
                          onShow: { coordinate, title in
                              map.move(to: coordinate)
                              withMotion(.spring(duration: 0.3)) {
                                  map.pressedPoint = MapPoint(coordinate: coordinate, title: title)
                              }
                          })
        }
        .sheet(isPresented: $map.showSettings) { SettingsView() }
        .sheet(isPresented: $map.showStats) {
            TripStatsSheet(onRoute: !env.location.hasLocation ? nil : { coord, name in
                buildRoute(to: coord, name: name)
            })
        }
        // Деталка из карточки «Поездка сохранена» — без захода в Итоги.
        .sheet(item: $tripEndDetail) { record in
            TripDetailSheet(record: record,
                            onRoute: !env.location.hasLocation ? nil : { coord, name in
                buildRoute(to: coord, name: name)
            })
        }
        .overlay { loadErrorOverlay }
        // Окно камеры читает дистанцию каждый тик — в фоне его не держим
        // (то же правило, что у слоёв выше).
        .overlay { if scenePhase != .background { approachOverlay } }
        // Пуш «Итоги поездки» и другие диплинки на статистику ведут сюда:
        // radarmap://trip — пуш и виджет недели на локскрине,
        // radarmap://stats — домашний виджет километров.
        .onOpenURL { url in
            guard url.scheme == "radarmap",
                  url.host() == "trip" || url.host() == "stats" else { return }
            // Поверх может быть другой шит — вторая презентация молча не
            // проходит, а «истинный» showStats делал кнопку Итогов мёртвой.
            // Закрываем всё своё и открываем Итоги после паузы на анимацию.
            map.selectedCamera = nil
            map.showNearbySheet = false
            map.showSearch = false
            map.showSettings = false
            showRouteCameras = false
            showMyPlaces = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                map.showStats = true
            }
        }
        .onChange(of: env.location.nearestCamera?.id) { _, _ in
            dismissedApproachID = nil   // новая ближайшая камера — снова показываем предупреждение
        }
        // Проезд чужой передвижной отметки отслеживает MobileCameraService на
        // каждом фиксе (LocationService.onAcceptedFix) — не вью: вью без
        // экрана не живёт, а onChange(locationTick) прямо здесь делал бы весь
        // body зависимым от тика.
        .onChange(of: env.location.isTripActive) { _, active in
            // Карта сама встаёт «по ходу движения» на старте и возвращается на
            // север после — но только если человек не выбирал ориентацию сам.
            // Раньше выбор терялся дважды за поездку, молча и поверх нажатой
            // кнопки (plan_app_ui.md, У10).
            if let next = MapState.orientationOnTripChange(
                active: active,
                current: map.orientation,
                chosenByHand: map.orientationChosenByHand) {
                map.apply(orientation: next,
                          coordinate: env.location.currentCoordinate,
                          course: env.location.currentCourse, inTrip: active)
            }
            if active {
                withMotion { tripEndRecord = nil }   // поехали снова — старый итог не актуален
                // Старт поездки — время для подсказок: про жёлтую кнопку (она
                // видна только в поездке) и про экран, если батарея тает без
                // зарядки. Спидометра, который открывался здесь сам и накрывал
                // карту, больше нет — карта за рулём остаётся картой.
                maybeShowHint()
                maybeSuggestScreenOffForBattery()
            } else {
                maybeShowTripEnd()
            }
        }
    }

    /// «Вы на месте» на экране — вместо панели поездки (TripScreenLayout).
    private var arrivalShown: Bool {
        TripScreenLayout.showsArrival(hasArrival: env.route.lastArrival != nil,
                                      isTripActive: env.location.isTripActive,
                                      showsTripEnd: tripEndRecord != nil)
    }

    @ViewBuilder private var approachOverlay: some View {
        #if DEBUG
        // -hideCameraAlert: снимаем чистые кадры turn-by-turn (алерт камеры
        // полноэкранный и перекрывает баннер манёвра).
        if ProcessInfo.processInfo.arguments.contains("-hideCameraAlert") {
            EmptyView()
        } else {
            ApproachOverlayGate(dismissedID: $dismissedApproachID)
        }
        #else
        ApproachOverlayGate(dismissedID: $dismissedApproachID)
        #endif
    }

    // MARK: - Карта

    /// Тема подложки: авто — по СОЛНЦУ в точке пользователя, не по будильнику.
    /// Прежние часы 6–19 врали дважды в год по часу: в декабре в 18:30 темно,
    /// а карта слепила белым. Без координаты — прежнее грубое правило (Sun).
    private var mapColorScheme: ColorScheme {
        switch env.settings.mapAppearance {
        case .dark:  return .dark
        case .light: return .light
        case .auto:
            // Точка для солнца — троттленный focus (шаг mapFocusStepMeters),
            // не живая координата: та пишется каждым фиксом, и тема «Авто»
            // делала body карты заложником тика + NOAA-расчёт каждую секунду.
            return Sun.isDaytime(at: map.focus ?? env.location.currentCoordinate,
                                 now: Date())
                ? .light : .dark
        }
    }

    /// Отдать схеме измеренные кромки панелей.
    ///
    /// Одной точкой, а не двумя вызовами из двух замеров: поля приходят
    /// парой, и половина пары — это неверная проекция на один кадр.
    private func applySketchInsets() {
        frame.setPanelEdges(top: topPanelEdge, bottom: bottomPanelEdge)
    }

    /// Подложка экрана: своя схема или карта Apple.
    ///
    /// Есть ли в сборке движок. Пакета может не быть — тогда его нет и в
    /// списке подложек, а не «есть, но молча не работает».
    static var engineAvailable: Bool {
        #if canImport(MapLibre)
        return true
        #else
        return false
        #endif
    }

    /// Подложка. Сам этот кусок body НЕ читает ничего, что пишется на тике:
    /// наша карта вынесена отдельной вью (MapBaseLayers), и чтение скорости,
    /// дистанции и координаты заперто внутри неё. Пока это лежало здесь,
    /// включённая своя карта пересобирала весь экран раз в секунду.
    @ViewBuilder
    private func baseLayer(scheme: ColorScheme) -> some View {
        // В фоне (свёрнуто, экран погашен) карты нет ВОВСЕ: вью карты оставалась
        // смонтированной, движок держал память GPU и тайлов, а body и
        // updateUIView крутились на каждом фиксе — в поездке часами. Фоновая
        // поездка живёт ради предупреждений, и пик памяти в 700+ МБ (jetsam,
        // docs/crash_carplay_memory.md) — ровно то, за что iOS её убивает.
        // `.inactive` (шторка, пункт управления) карту не трогает: это секунды.
        if scenePhase == .background {
            Theme.background.ignoresSafeArea()
        } else {
            mapBase(scheme: scheme)
        }
    }

    @ViewBuilder
    private func mapBase(scheme: ColorScheme) -> some View {
        #if canImport(MapLibre)
        // Карту рисует движок — единственная подложка с 11.10 (карта Apple и
        // схема убраны по слову владельца). Панели поверх — те же: они про
        // скорость и камеры, а не про подложку.
        EngineBaseLayer(onSelectCamera: { map.select($0) },
                        onLongPress: { selectPoint(at: $0) },
                        state: frame, map: map)
            .ignoresSafeArea()
        #else
        // Без пакета движка карты нет вовсе: это сборочный выключатель, а не
        // режим приложения. Предупреждения о камерах работают и без неё.
        ZStack {
            Theme.background.ignoresSafeArea()
            Text("Карта недоступна в этой сборке")
                .font(.rounded(15, .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        #endif
    }

    // MARK: - Разовые подсказки

    /// Показать следующую невиданную подсказку (максимум одну за запуск).
    /// Решение «какую» — чистый OneTimeHints; здесь только Storage и таймер.
    private func maybeShowHint() {
        guard Storage.bool(.hasCompletedOnboarding), !hintConsumedThisLaunch,
              activeHint == nil, !map.isAddingCamera else { return }
        var shown: Set<OneTimeHints.Hint> = []
        if Storage.bool(.hintTogglesShown) { shown.insert(.toggles) }
        if Storage.bool(.hintRadarShown) { shown.insert(.radar) }
        if Storage.bool(.hintSilenceShown) { shown.insert(.smartSilence) }
        guard let hint = OneTimeHints.next(
            shown: shown,
            radarVisible: mode.showsReportButton,
            hasFamiliarCameras: !env.location.familiarCameraIDs.isEmpty) else { return }
        hintConsumedThisLaunch = true
        switch hint {
        case .toggles:   Storage.set(true, for: .hintTogglesShown)
        case .radar:     Storage.set(true, for: .hintRadarShown)
        case .smartSilence: Storage.set(true, for: .hintSilenceShown)
        }
        withMotion(.spring(duration: 0.3)) { activeHint = hint }
        Task {
            await Task.pause(seconds: 7)
            withMotion(.easeOut(duration: 0.3)) { activeHint = nil }
        }
    }

    /// «Батарея садится — погасите экран»: поездка началась, зарядки нет,
    /// батарея ниже трети. Раньше здесь звали в спидометр; его нет, а честный
    /// совет один — экран и есть главный потребитель, и гасить его можно:
    /// при доступе «Всегда» предупреждения звучат и с погашенным экраном. Без
    /// «Всегда» это было бы неправдой, поэтому совет только с ним.
    /// Мониторинг батареи включается на один замер и тут же гасится — держать
    /// его постоянно ради подсказки было бы иронией на тему экономии.
    private func maybeSuggestScreenOffForBattery() {
        guard env.location.authorizationStatus == .authorizedAlways else { return }
        let battery = BatteryProbe.snapshot()
        guard let percent = battery.percent, percent < 30, !battery.isCharging else { return }
        withMotion(.spring(duration: 0.3)) { showBatterySaverHint = true }
        Task {
            await Task.pause(seconds: 8)
            withMotion(.easeOut(duration: 0.3)) { showBatterySaverHint = false }
        }
    }

    // MARK: - Умные кнопки

    // Автоскрытие интерфейса УДАЛЕНО, и это не упрощение ради упрощения.
    //
    // Механизм заводился правильной мыслью — в поездке максимум экрана отдан
    // карте, — но по факту не делал ничего. Он включался только под `guard
    // env.location.isTripActive`, а прятал ровно три вещи: легенду типов
    // камер, нижний бар действий и разовые подсказки. Все три показываются
    // ТОЛЬКО в покое (MapMode.showsLegend, showsActionBar). Таймер на пять
    // секунд, задача на каждое касание и анимация двух слоёв работали ради
    // состояния, которого не бывает.
    //
    // Проверять такие механизмы надо перебором режимов, а не на глаз: в план
    // я сначала записал «прячет нужное» — и это оказалось неверно.

    private var crosshair: some View {
        Image(systemName: "scope")
            .font(.system(size: 44, weight: .light))
            .foregroundStyle(Theme.accent)
            .shadow(color: .black.opacity(0.5), radius: 4)
            .allowsHitTesting(false)
    }

    // MARK: - Верх: HUD + подсказка

    /// Панели поверх карты сверху: объявления, HUD, тумблеры, манёвр.
    ///
    /// Отдельным свойством не ради красоты, а ради ЗАМЕРА: схеме нужно знать,
    /// докуда её закрыли, и мерить надо ровно эти панели — без кнопок справа
    /// (они не поперёк экрана) и без распорки.
    @ViewBuilder
    private var topPanels: some View {
        VStack(spacing: 10) {
            // The next turn stays at a fixed top position as statuses appear.
            ManeuverBannerGate()
            // В навигации сверху — ОДНА карточка, манёвр. Камера на подходе —
            // компактным чипом под ней; скорость с лимитом — внизу слева
            // (bottomLayer). Две крупные карточки занимали треть экрана.
            if mode.speedPlacement == .bottomLeading {
                TripCameraChip()
            }
            // Почему приложение работает не в полную силу: объявление сервера,
            // серая карта без сети, урезанная карта в жару, отсутствие лимитов.
            // Выше всего, потому что человек должен узнать причину раньше, чем
            // упрётся в неё сам и решит, что приложение сломалось.
            MapStatusBanner(modernMap: env.settings.mapModernStyle)
            // Доступ к геопозиции — сразу под объявлениями сервера, а не внизу
            // поверх карты: это причина, по которой приложение не предупреждает
            // в фоне, и место ей рядом с остальными «почему не в полную силу».
            permissionBanner
            // Тап по HUD — быстрые тумблеры оповещений (долгий тап — тоже).
            // HUD сверху всегда компактный: в покое главное «куда поедем», а в
            // поездке без маршрута полноразмерная карточка занимала пятую часть
            // экрана ради двух чисел. В навигации его здесь нет вовсе.
            if mode.speedPlacement == .top {
                hudGestures(SpeedHUDView(secondary: true))
            }
            // Разовые подсказки по жестам и экономии — по одной, не простынёй.
            if let hint = activeHint {
                HintChip(text: hint.text)
            }
            if showBatterySaverHint {
                HintChip(text: String(localized: "Батарея садится — погасите экран, о камерах скажу голосом"),
                         tint: Theme.success)
            }
            // «Я в такси»: приложение молчит осознанно — человек должен видеть,
            // почему нет оповещений, и уметь передумать одним тапом.
            if env.location.isPassengerSession {
                passengerChip
            }
            // Быстрые тумблеры — ПОСЛЕДНИМИ в стопке, и это не про красоту.
            //
            // Раскрывались они между HUD и манёвром, то есть сдвигали баннер
            // манёвра вниз на свою высоту — треть экрана. Главный элемент
            // навигации уезжал из-под взгляда ровно в тот момент, когда
            // водитель тянется к экрану заглушить голос; вернуть его на место
            // мог только повторный тап. Панель открывают осознанно и закрывают
            // сразу, а поворот на перекрёстке ждать не умеет — поэтому растёт
            // она вниз, поверх карты, и ничто над ней не двигается
            // (plan_app_ui.md, У11).
            if showQuickToggles {
                QuickTogglesBar {
                    withMotion(.spring(duration: 0.3)) { showQuickToggles = false }
                }
            }
        }
    }

    private var topLayer: some View {
        VStack(spacing: 10) {
            topPanels
                // Кромка панелей — схеме.
                //
                // Схема лежит во весь экран, а видно из неё столько, сколько
                // оставили панели: 17 % высоты забирает карточка скорости, 26 %
                // — она же с объявлением о перегреве. Пока проекция считала от
                // ПОЛНОГО экрана, тревожная камера садилась на 12 % сверху, то
                // есть ПОД карточкой: на снимке живой поездки «344 м до камеры»
                // в карточке и ни одной камеры на карте.
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: {
                    topPanelEdge = $0 + 8
                    applySketchInsets()
                    updateColumnSlots()
                }
            // Кнопки навигации — сразу под HUD справа. Не прячутся по таймеру
            // (см. controlColumn), но уходят под карточкой прибытия: это
            // последний экран поездки, и крутить карту в этот момент незачем.
            if TripScreenLayout.showsControlColumn(arrivalShown: arrivalShown,
                                                   isAddingCamera: map.isAddingCamera) {
                HStack {
                    Spacer()
                    controlColumn
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Вход HUD — быстрые тумблеры (звук, вибро, голос). Один и тот же у HUD
    /// сверху и у скорости внизу слева в навигации — жест не должен зависеть
    /// от того, где сейчас стоит цифра.
    ///
    /// Тап раньше открывал спидометр, а тумблеры жили за долгим тапом, о
    /// котором рассказывала отдельная подсказка. Спидометр убран, и тап
    /// достался тому, ради чего к HUD тянутся на ходу, — «хватит болтать».
    /// Долгий тап оставлен с тем же действием: рука, привыкшая к нему, не
    /// должна наткнуться на пустоту.
    private func hudGestures(_ content: some View) -> some View {
        content
            .onTapGesture { toggleQuickToggles() }
            .onLongPressGesture(minimumDuration: 0.4) { toggleQuickToggles() }
            // Жестов для VoiceOver не существует — вход даём действием.
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text("Открывает быстрые тумблеры"))
            .accessibilityAction { toggleQuickToggles() }
    }

    private func toggleQuickToggles() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withMotion(.spring(duration: 0.3)) { showQuickToggles.toggle() }
    }

    /// Баннер пассажирского режима: молчание — осознанное, выход — один тап.
    private var passengerChip: some View {
        Button {
            // Тот же путь, что «Я за рулём» из уведомления: сброс пассажирского
            // флага, запоминание магнитолы, старт поездки.
            env.location.confirmDriver()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "figure.seated.seatbelt")
                    .font(.rounded(13, .semibold))
                Text("Вы пассажир — оповещения выключены")
                    .font(.rounded(12, .semibold))
                Spacer(minLength: 4)
                Text("Я за рулём")
                    .font(.rounded(12, .bold))
                    .foregroundStyle(Theme.accent)
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 14)
            .frame(minHeight: Theme.controlSize)
            .backport.glassEffect(.regular, in: .capsule)
        }
        .buttonStyle(PressableStyle())
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Колонка навигации (компас, локация, зум)

    /// Две кнопки — и обе живут постоянно, не прячась по таймауту.
    ///
    /// Раньше колонка пряталась целиком через 5 секунд бездействия в поездке, и
    /// вместе с ней исчезала кнопка «Радар здесь!» — то есть единственный способ
    /// отметить треногу пропадал ровно тогда, когда мимо треноги едешь. Прятать
    /// нужно хром (легенду, быстрые цели, бар действий), а не органы управления.
    private var controlColumn: some View {
        VStack(spacing: 12) {
            if mode.keepsMapToolsInMenu {
                tripControls
            } else {
                idleControls
            }
            // Зум — щипком, как в Apple Maps: кнопки только занимали место.
        }
        .motionAnimation(.spring(duration: 0.3), value: mode.keepsMapToolsInMenu)
    }

    /// В поездке — три кнопки: звук, ориентация, «…». Слои, 3D, «весь
    /// маршрут» и разделы приложения — пунктами меню. Семь кругов столбиком закрывали
    /// треть карты справа, а на ходу из них нажимают звук и «к машине»
    /// (docs/plan_drive_ux_2026-10-07.md, п. 4). Компас — только когда карту
    /// повернули руками.
    @ViewBuilder private var tripControls: some View {
        let extras = TripScreenLayout.columnExtras(
            slots: columnSlots, fixed: 3,
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
    @ViewBuilder private var idleControls: some View {
        // Обязательные — слои, «к себе» и звук (слои в покое — единственный
        // вход в смену подложки); остальное по важности, пока есть место до
        // нижних панелей (TripScreenLayout.columnExtras).
        let extras = TripScreenLayout.columnExtras(
            slots: columnSlots, fixed: 3,
            candidates: (map.isRotated ? [(.compass, 1)] : [])
                + (env.route.isActive ? [(.overview, 1)] : [])
                + [(.threeD, 1)]
                + (env.settings.mapZoomButtons ? [(.zoom, 2)] : []))
        // Слои карты — первой в колонке.
        //
        // Подложка лежала в десятом разделе настроек и включалась только
        // после старта поездки; пробки и места жили в отдельной панели,
        // которой в поездке не бывало вовсе. Теперь это одна панель; в
        // поездке та же панель — подменю «…» (mapLayersMenu).
        MapLayersControl(traffic: setting(\.trafficShown),
                         places: setting(\.mapPlaces),
                         houses: setting(\.mapHouses),
                         sidewalks: setting(\.mapSidewalks),
                         maxPanelHeight: columnSlots.map {
                             CGFloat($0) * AppConfig.mapColumnSlotHeight - AppConfig.mapColumnSpacing
                         } ?? .infinity)
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
    private func updateColumnSlots() {
        let measured = topPanelEdge > 0 && bottomPanelEdge > 0
        let slots = TripScreenLayout.columnSlots(room: measured ? bottomPanelEdge - topPanelEdge : nil)
        if slots != columnSlots { columnSlots = slots }
    }

    private var orientationControl: some View {
        MapOrientationControl(orientation: map.orientation) {
            map.cycleOrientation(coordinate: env.location.currentCoordinate,
                                 course: env.location.currentCourse,
                                 inTrip: env.location.isTripActive)
        }
    }

    /// Привязка к настройке без восьми одинаковых `Binding(get:set:)`.
    private func setting<Value>(_ keyPath: ReferenceWritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        let settings = env.settings
        return Binding(get: { settings[keyPath: keyPath] },
                       set: { settings[keyPath: keyPath] = $0 })
    }

    /// Вид карты в меню «…» поездки: то, что в покое стоит кнопками колонки.
    @ViewBuilder private var mapViewItems: some View {
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

    /// Слои подменю: те же переключатели, что в панели MapLayersControl, и
    /// по тем же правилам — пробки только у Apple, застройка только у нашей карты.
    private var mapLayersMenu: some View {
        Menu {
            Toggle(isOn: setting(\.trafficShown)) {
                Label("Пробки", systemImage: "car.2.fill")
            }
            Toggle(isOn: setting(\.mapPlaces)) {
                Label("Места", systemImage: "fuelpump.fill")
            }
            Toggle(isOn: setting(\.mapHouses)) {
                Label("Дома", systemImage: "building.2.fill")
            }
            Toggle(isOn: setting(\.mapSidewalks)) {
                Label("Тротуары", systemImage: "figure.walk")
            }
        } label: {
            Label("Слои карты", systemImage: "square.3.layers.3d")
        }
    }

    // MARK: - Низ: панель действий / режим добавления

    /// Панели поверх карты снизу: панель поездки, плашки, кнопки действий.
    ///
    /// Отдельным свойством по той же причине, что и верхние: схема обязана
    /// знать, докуда её закрыли снизу, а измерить это можно только у самих
    /// панелей — у стопки с распоркой высота всегда во весь экран.
    @ViewBuilder
    private var bottomPanels: some View {
        VStack(spacing: 10) {
            if map.isAddingCamera {
                AddCameraBar(
                    onCancel: { map.isAddingCamera = false },
                    onAdd: { kind, name in addCamera(kind: kind, name: name) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let point = map.pressedPoint {
                MapPointBar(
                    title: point.title,
                    onRoute: !env.location.hasLocation ? nil : {
                        buildRoute(to: point.coordinate, name: point.title ?? String(localized: "Точка на карте"))
                        withMotion { map.pressedPoint = nil }
                    },
                    onRadar: {
                        withMotion {
                            map.pressedPoint = nil
                            reportPoint = point   // дальше — выбор типа отметки
                        }
                    },
                    onOwnCamera: {
                        // Крестик режима добавления встаёт на выбранную точку —
                        // пользователь при желании доводит позицию вручную.
                        withMotion {
                            map.pressedPoint = nil
                            map.center(on: point.coordinate)
                            map.isAddingCamera = true
                        }
                    },
                    onCancel: {
                        withMotion { map.pressedPoint = nil }
                    }
                )
            } else if let report = reportPoint {
                ReportPickerBar(
                    onPick: { kind in
                        // Место показано пальцем, тип выбран из списка — это
                        // осознанная постановка: проверку «вы стоите» она
                        // проходит, а защиту от дублей и счётчик получает.
                        // Отклик — ПО ИТОГУ, а не сразу: прежний безусловный
                        // «успех» звучал одинаково и когда отметка ушла, и
                        // когда её отбросили как дубль.
                        Task {
                            let outcome = await env.mobile.quickReport(
                                kind: kind,
                                coordinate: report.coordinate,
                                speedKmh: env.location.speedKmh,
                                isTripActive: env.location.isTripActive,
                                placement: .deliberate)
                            UINotificationFeedbackGenerator()
                                .notificationOccurred(outcome.isSuccess ? .success : .warning)
                        }
                        withMotion { reportPoint = nil }
                    },
                    onCancel: { withMotion { reportPoint = nil } }
                )
            } else {
                // «Радар ещё стоял?» — над панелью поездки: вопрос живёт
                // двадцать секунд и уходит сам, ничего не отправляя. Пока на
                // экране предупреждение о камере, вопрос ждёт: камера важнее,
                // а под оверлеем плашка сгорала невидимой.
                // Условие «накрыто» — в гейте: isApproachingCamera читает
                // пер-тиковые дистанцию и скорость (см. MapTickGates).
                MobileConfirmGate()
                // «Что это было?» — уточнение типа сразу после «Радар!»:
                // тот же гейт-паттерн и то же место над панелью поездки.
                ReportRefineGate()
                // Итог поездки — сразу после стопа, в момент, когда цифры
                // интереснее всего (см. maybeShowTripEnd про условия показа).
                if let record = tripEndRecord {
                    TripEndCard(
                        record: record,
                        onDetail: { chosen in
                            withMotion(.spring(duration: 0.3)) { tripEndRecord = nil }
                            tripEndDetail = chosen
                        },
                        onMerged: { tripEndRecord = env.trip.history.first },
                        onDismiss: {
                            withMotion(.spring(duration: 0.3)) { tripEndRecord = nil }
                        })
                }
                if arrivalShown, let arrival = env.route.lastArrival {
                    // «Вы на месте» — НА МЕСТЕ панели поездки, а не поверх
                    // экрана: у карточки своя «Завершить поездку», и второй
                    // «стоп» рядом с ней означал бы вопрос, какой настоящий.
                    ArrivalCardView(arrival: arrival, onDismiss: {
                        withMotion(.spring(duration: 0.3)) { env.route.dismissArrival() }
                    })
                } else if TripScreenLayout.showsTripBar(mode: mode, arrivalShown: arrivalShown) {
                    // Панель поездки — ниже, после всей цепочки: одна на все
                    // ветки (см. там). Здесь ветка лишь занимает её место,
                    // чтобы маршрут и подсказки не встали вместо неё.
                    EmptyView()
                } else if mode.showsRoutePanel, env.route.isActive {
                    RoutePanel(
                        onShowCameras: { showRouteCameras = true },
                        onTripToggle: { toggleTrip() }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    // ОДНА плашка, а не четыре разом.
                    //
                    // Каждая заводилась по своей причине и права по
                    // отдельности; вместе они делили внимание на четыре — за
                    // рулём, где на взгляд есть доля секунды. Приоритет
                    // считается один раз (BottomHint.choose) и не
                    // оспаривается: требующее решения старше сообщающего.
                    switch BottomHint.choose(
                        routeError: env.route.errorMessage,
                        isBuilding: env.route.isBuilding,
                        isProbablyDriving: env.location.isProbablyDriving,
                        showsQuickDestinations: mode.showsQuickDestinations) {
                    case .routeError(let error):
                        // Тап убирает ошибку — значит, это кнопка, и мишень у
                        // неё 44 pt (была капсула ~28 pt под onTapGesture).
                        Button { env.route.clear() } label: {
                            Text(error)
                                .font(.rounded(12, .medium)).foregroundStyle(Theme.danger)
                                .padding(.horizontal, 14)
                                .frame(minHeight: Theme.controlSize)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityHint(Text("Убрать сообщение"))
                    case .building:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Строим маршрут…")
                                .font(.rounded(12, .medium)).foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                    case .driving:
                        DrivingHintChip()
                    case .destinations:
                        // Куда поедем — одной строкой и только когда есть
                        // уверенная догадка. Два круга Дом/Работа стояли здесь
                        // всегда, и незаданные выглядели невыполненным
                        // заданием от приложения человеку; распорядок оно
                        // знает само (FrequentPlaces).
                        // Разовое «Карта без интернета?» — до первого ответа.
                        OfflineOfferCard(ownMap: true)
                        DestinationSuggestionBar { coordinate, name in
                            buildRoute(to: coordinate, name: name)
                        }
                        tripButton
                    case .none:
                        EmptyView()
                    }
                }
                if mode.showsActionBar {
                    actionBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // В поездке: компактная строка (прибытие · остаток · камера · стоп) —
            // максимум экрана отдан карте, и она не прячется вместе с кнопками.
            //
            // ОДНА на все ветки и всегда последним ребёнком стопки. Точка на
            // карте или выбор типа отметки встают НАД ней: раньше долгий тап
            // на ходу убирал «Радар!» и «Стоп», а когда панель вернули второй
            // копией в другой ветке, SwiftUI считал их разными видами — на
            // 0,3 с анимации на экране было две панели и сбрасывался
            // взведённый «Стоп».
            if !map.isAddingCamera,
               TripScreenLayout.showsTripBar(mode: mode, arrivalShown: arrivalShown) {
                TripLiveBar(
                    onShowCameras: { showRouteCameras = true },
                    onStop: { toggleTrip() }
                )
            }
        }
    }

    private var bottomLayer: some View {
        VStack(spacing: 10) {
            Spacer()
            // Скорость и лимит в навигации — внизу слева, над панелью поездки.
            // Вне замера кромки: это угол, а не полоса поперёк экрана, и
            // карта под ним видна справа.
            if mode.speedPlacement == .bottomLeading, !arrivalShown, !map.isAddingCamera {
                HStack {
                    hudGestures(TripSpeedCluster())
                    Spacer(minLength: 0)
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            bottomPanels
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: {
                    bottomPanelEdge = $0 - 8
                    applySketchInsets()
                    updateColumnSlots()
                }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .motionAnimation(.spring(duration: 0.3), value: map.isAddingCamera)
        .motionAnimation(.spring(duration: 0.3), value: map.pressedPoint)
        .motionAnimation(.spring(duration: 0.3), value: reportPoint)
        .motionAnimation(.spring(duration: 0.3), value: arrivalShown)
    }

    /// Долгий тап: маркер + бар действий (кроме режима прицела добавления камеры).
    private func selectPoint(at coordinate: CLLocationCoordinate2D) {
        guard !map.isAddingCamera else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withMotion(.spring(duration: 0.3)) {
            map.pressedPoint = MapPoint(coordinate: coordinate)
        }
    }

    private func toggleTrip() {
        if env.location.isTripActive {
            env.location.endTrip()
        } else {
            env.location.startTrip()
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Показать «Поездка сохранена» после стопа. Только на переднем плане
    /// (автозавершение в кармане обслуживает уведомление, а не карточка,
    /// которую никто не видит), только для свежесохранённой записи (короче
    /// 100 м поездка не пишется вовсе — свежести нет, карточки нет) и не
    /// поверх открытых Итогов — там те же цифры уже на экране.
    private func maybeShowTripEnd() {
        // Свежесть — по моменту СОХРАНЕНИЯ, а не по endedAt записи: endedAt —
        // это последний фикс, а на стоянке фиксов нет. Минута у подъезда — и
        // только что сохранённая поездка считалась старой, карточка не
        // появлялась, и поездка выглядела пропавшей («после него куда делся»).
        guard scenePhase == .active, !map.showStats,
              TripScreenLayout.isTripEndFresh(savedAt: env.trip.lastSavedAt, now: Date()),
              let record = env.trip.history.first else { return }
        withMotion(.spring(duration: 0.4)) {
            tripEndRecord = record
            // Итог поездки сказал всё, что говорила карточка прибытия, и больше.
            env.route.dismissArrival()
        }
    }

    /// Построить авто-маршрут от текущей позиции и показать все варианты целиком.
    /// Заезд по пути (АЗС, кафе из плитки категории): цель остаётся прежней.
    private func addStop(_ coordinate: CLLocationCoordinate2D, name: String) {
        Task {
            guard let from = await env.location.awaitPreciseCoordinate() else {
                env.route.reportNoFix()
                return
            }
            await env.route.addStop(coordinate, name: name, from: from,
                                    cameras: env.cameras.cameras)
        }
    }

    private func buildRoute(to coordinate: CLLocationCoordinate2D, name: String) {
        Task {
            // Только от ЖИВОЙ точки. Раньше здесь стоял currentCoordinate без
            // проверки isPositionCoarse — а в него пишется и грубая точка
            // фонового режима, из-за чего маршрут «начинал считаться» за
            // километры от машины (plan_drive_complaints.md, Ж5).
            guard let from = await env.location.awaitPreciseCoordinate() else {
                env.route.reportNoFix()
                return
            }
            await env.route.build(from: from, to: coordinate, name: name,
                                  cameras: env.cameras.cameras,
                                  alternatives: env.settings.routeAlternatives)
            guard env.route.isActive else { return }
            env.settings.addRecent(title: name, lat: coordinate.latitude, lon: coordinate.longitude)
            // Охватываем ВСЕ варианты, чтобы выбор был виден сразу.
            var rect = MKMapRect.null
            for variant in env.route.variants { rect = rect.union(variant.polyline.boundingMapRect) }
            // Показываем маршрут целиком — это уже не слежение за точкой;
            // общая команда видна и карте Apple, и движку.
            map.showRouteOverview(rect: rect)
        }
    }

    /// «Начать поездку»: громкость кнопки решает правило, а не вёрстка.
    @ViewBuilder
    private var tripButton: some View {
        switch TripStartPrompt.prominence(
            startsByItself: env.settings.tripStartMode.usesMotion) {
        case .primary:   tripButtonPrimary
        case .secondary: tripButtonSecondary
        }
    }

    /// Запасной выход там, где поездка начнётся и без него. Язык тот же, что у
    /// «Я пассажир»: серый текст на Theme.surface — видно, но не кричит.
    private var tripButtonSecondary: some View {
        Button {
            toggleTrip()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill").font(.rounded(11, .semibold))
                Text("Начать поездку").font(.rounded(13, .semibold))
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 14)
            .frame(minHeight: Theme.controlSize)
            .background(Theme.surface, in: Capsule())
        }
        .buttonStyle(PressableStyle())
    }

    /// CTA для тех, у кого автостарт выключен: без нажатия поездки не будет
    /// вовсе. Та же главная кнопка, что «Поехали» и «Отправить» — жёлтая
    /// PrimaryButton; был зелёный градиент-капсула, третий облик одной роли.
    private var tripButtonPrimary: some View {
        PrimaryButton(title: "Начать поездку", systemImage: "play.fill") { toggleTrip() }
            .liftAccent()
    }

    /// Док действий: стекло со световой кромкой и глубокая тень — в одном
    /// языке с CTA и кругами (премиальный низ экрана без разнобоя).
    /// Четыре постоянных действия — больше глазу не нужно. Редкое «добавить
    /// свою камеру» живёт в меню «Ещё»: оно нужно раз в месяц, а место в баре
    /// занимало всегда (plan_main_screen.md, шаг 4).
    private var actionBar: some View {
        HStack(spacing: 4) {
            actionButton("Поиск", "magnifyingglass") { map.showSearch = true }
            // «Мои места» — на месте спидометра, который владелец попросил
            // убрать («мне кажется не нужен»). Дорога домой или на работу —
            // самое частое, что навигатор делает одним тапом; у Яндекса и
            // Amap «Мои места» живут ровно здесь. Раньше Дом и Работа были
            // строкой внутри «Поиска», то есть в двух тапах и под клавиатурой.
            //
            // «Рядом» сюда не вернулся по прежней причине: список камер
            // поблизости открывался с экрана, который эти же камеры уже
            // показывает на карте, — он живёт в «Ещё».
            actionButton("Мои места", "star.fill") { showMyPlaces = true }
            actionButton("Итоги", "chart.bar.fill") { map.showStats = true }
            Menu {
                moreActionItems
            } label: {
                actionLabel("Ещё", "ellipsis.circle.fill")
            }
            .accessibilityLabel(Text("Ещё"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .backport.glassEffect(.regular, in: .rect(cornerRadius: Theme.cornerPanel))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous)
            .strokeBorder(Theme.edgePanel, lineWidth: 1))
        .liftPanel()
    }

    /// Пункты меню поездки: то, что в покое лежит в нижнем баре.
    ///
    /// Один список на оба входа. Разойдутся они мгновенно, стоит завести
    /// второй, — это уже было с двумя жёлтыми кнопками «Радар», у которых
    /// одинаковый вид давал разное действие.
    @ViewBuilder private var tripActionItems: some View {
        Button { map.showSearch = true } label: {
            Label("Поиск", systemImage: "magnifyingglass")
        }
        Button { showMyPlaces = true } label: {
            Label("Мои места", systemImage: "star.fill")
        }
        Button { map.showStats = true } label: {
            Label("Итоги", systemImage: "chart.bar.fill")
        }
        moreActionItems
    }

    /// Редкое: в баре место занимало бы всегда, а нужно раз в месяц.
    @ViewBuilder private var moreActionItems: some View {
        // «Рядом» переехал сюда из бара. Не удалён: список с расстояниями
        // иногда удобнее карты — например, пассажиру или когда карта ещё
        // грузится. Но постоянного места он не заслуживает, потому что
        // отвечает на тот же вопрос, что и карта под ним.
        Button { map.showNearbySheet = true } label: {
            Label("Рядом", systemImage: "list.bullet")
        }
        Button {
            withMotion { map.isAddingCamera = true }
        } label: {
            Label("Добавить камеру", systemImage: "plus.circle.fill")
        }
        Button { map.showSettings = true } label: {
            Label("Настройки", systemImage: "gearshape.fill")
        }
    }

    private func actionButton(_ title: LocalizedStringKey, _ icon: String, tint: Color = Theme.textPrimary,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            actionLabel(title, icon, tint: tint)
        }
        .buttonStyle(PressableStyle())
    }

    /// Общая разметка кнопки бара — её же носит меню «Ещё».
    private func actionLabel(_ title: LocalizedStringKey, _ icon: String,
                             tint: Color = Theme.textPrimary) -> some View {
        VStack(spacing: 5) {
                Image(systemName: icon).font(.rounded(19, .semibold))
                Text(title)
                    .font(.rounded(10, .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
    }

    @ViewBuilder private var permissionBanner: some View {
        if let banner = bannerInfo {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                Text(banner.message).font(.rounded(12)).foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                // Мишень 44 pt: была голая подпись 12 pt (~16 pt в высоту).
                // Оформление — ВНУТРИ кнопки: нажимается её метка, и капсула
                // снаружи была бы 44 pt только на вид.
                Button(action: banner.action) {
                    Text(banner.button)
                        .font(.rounded(15, .semibold)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 14)
                        .frame(minHeight: Theme.controlSize)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
        }
    }

    @ViewBuilder private var loadErrorOverlay: some View {
        if let error = env.loadError {
            ContentUnavailableView("Не удалось загрузить камеры",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        }
    }

    // MARK: - Действия

    private func addCamera(kind: AddKind, name: String) {
        guard let center = map.mapCenter else {
            withMotion { map.isAddingCamera = false }
            return
        }
        switch kind {
        case .camera, .radar:
            let type: CameraType = kind == .radar ? .stationaryRadar : .stationaryCamera
            env.cameras.addCamera(at: center, type: type, label: name)   // revision → onChange обновит карту
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .mobile:
            Task {
                let outcome = await env.mobile.quickReport(
                    coordinate: center,
                    speedKmh: env.location.speedKmh,
                    isTripActive: env.location.isTripActive,
                    placement: .deliberate)
                UINotificationFeedbackGenerator()
                    .notificationOccurred(outcome.isSuccess ? .success : .error)
            }
        }
        withMotion { map.isAddingCamera = false }
    }

    private var bannerInfo: (message: String, button: String, action: () -> Void)? {
        switch env.location.authorizationStatus {
        case .denied, .restricted:
            return (String(localized: "Геолокация выключена. Включите «Всегда» для оповещений о камерах."),
                    String(localized: "Настройки"), openSettings)
        case .authorizedWhenInUse:
            return (String(localized: "Для фоновых оповещений выберите доступ «Всегда»."),
                    String(localized: "Настройки"), openSettings)
        default:
            break
        }
        if env.location.isAuthorized && !env.location.hasFullAccuracy {
            return (String(localized: "Включена приблизительная геолокация — оповещения о камерах будут неточными."),
                    String(localized: "Включить точную"), { env.location.requestPreciseLocation() })
        }
        if env.notifications.authorizationStatus == .denied {
            return (String(localized: "Уведомления выключены — вы не услышите сигнал о камере."),
                    String(localized: "Настройки"), openSettings)
        }
        return nil
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    #if DEBUG
    /// Скриншот-автоматизация (симулятор): `simctl launch <app> -showStats | -showSettings |
    /// -showCameraDetail` открывает нужный экран без тапов. В релизную сборку не попадает.
    private func openScreenFromLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        // Демо-история для визуальной проверки Итогов и отчёта за период.
        // -demoBigNumbers: та же история, но с четырёхзначными километрами —
        // вёрстку Итогов надо проверять на числах, которые бывают в жизни, а не
        // на демонстрационных 12,4 км.
        if args.contains("-demoHistory") {
            env.trip.seedDemoHistory(scale: args.contains("-demoBigNumbers") ? 20 : 1)
        }
        if args.contains("-demoMergePair") { env.trip.seedDemoMergePair() }
        // С паузой: настоящие пробки приходят уже после загрузки карты, и
        // слой обязан перерисоваться на новом наборе, а не только на старте.
        if args.contains("-demoTraffic") {
            Task {
                await Task.pause(seconds: 3)
                env.traffic.seedDemo()
            }
        }
        // Дорога на работу и домой: четыре недели будней поверх истории.
        if args.contains("-demoCommutes") {
            env.trip.seedDemoCommutes()
            env.refreshLearnedPlaces()
        }
        // Демо-история двухнедельной давности: проверка «в этом периоде поездок нет».
        if args.contains("-demoHistoryOld") { env.trip.seedDemoHistory(shiftDays: 14) }
        if args.contains("-showStats") { map.showStats = true }
        if args.contains("-showSettings") { map.showSettings = true }
        if args.contains("-showMyPlaces") { showMyPlaces = true }
        if args.contains("-showCameraDetail") {
            Task {
                await Task.pause(seconds: 1.5)
                if let coordinate = env.location.currentCoordinate,
                   let camera = env.cameras.nearest(to: coordinate, limit: 1).first {
                    map.select(camera)
                }
            }
        }
        // Детерминированный тест навигации: строим маршрут к фиксированной точке
        // Ташкента (просп. Амира Темура) от текущей позиции. С -driveDemo сразу
        // стартуем поездку (как «Поехали») — для прогонки движения по маршруту.
        // Повернуть карту (компас должен появиться): жестов у simctl нет.
        if args.contains("-rotateMap") {
            Task {
                // После snapToUserOnce (тот перебил бы позицию своим регионом).
                await Task.pause(seconds: 6)
                guard let center = env.location.currentCoordinate else { return }
                withMotion(.easeInOut(duration: 0.6)) {
                    map.position = .camera(MapCamera(centerCoordinate: center,
                                                     distance: 1200, heading: 45))
                }
            }
        }
        // Шеринг-карточки в PNG (Documents) — визуальная проверка без share-шита.
        if args.contains("-dumpShareCards") {
            Task {
                await Task.pause(seconds: 2)
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let last = env.trip.fallbackRecord(isTripActive: env.location.isTripActive)
                    ?? env.trip.history.first
                // Период берём тот, где данные ЕСТЬ: демо-история после
                // полуночи попадает в прошлую календарную неделю, и дамп
                // рисовал карточку из одних нулей (поймано на живом дампе).
                let period: StatsPeriod = .month
                let anchor = env.trip.history.first?.startedAt ?? Date()
                let summary = TripHistory.summary(days: env.trip.days, history: env.trip.history,
                                                  period: period, anchor: anchor)
                let passes = TripHistory.records(env.trip.history, period: period,
                                                 anchor: anchor).flatMap(\.passed)
                let tracks = TripHistory.records(env.trip.history, period: period, anchor: anchor)
                    .flatMap(\.trackPoints)
                let periodMap = await TripMapSnapshot.render(
                    track: tracks, passes: passes, size: CGSize(width: 1032, height: 420))
                let tripMap = await TripMapSnapshot.render(
                    track: last?.trackPoints ?? [], passes: last?.passed ?? [],
                    size: CGSize(width: 1032, height: 840))
                let badge = Achievements.all(for: env.trip.lifetime).first(where: \.earned)

                // Оба формата: сторис ломается иначе, чем лента, и увидеть
                // это нужно до отправки, а не у собеседника.
                for format in ShareFormat.allCases {
                    @MainActor func write(_ view: some View, _ name: String) {
                        let renderer = ImageRenderer(content: view)
                        renderer.scale = 2
                        renderer.proposedSize = ProposedViewSize(format.size)
                        try? renderer.uiImage?.pngData()?
                            .write(to: docs.appendingPathComponent("\(name)_\(format.rawValue).png"))
                    }
                    write(PeriodShareCard(summary: summary, periodTitle: period.rangeTitle(containing: anchor),
                                          mapImage: periodMap, format: format), "share_stats")
                    if let record = last {
                        write(TripShareCard(record: record, mapImage: tripMap, format: format), "share_trip")
                    }
                    if let badge {
                        write(AchievementShareCard(badge: badge, lifetime: env.trip.lifetime,
                                                   format: format), "share_badge")
                    }
                }
            }
        }
        // Пикер типа отметки / тумблеры / вопрос «вы за рулём?» — для скриншотов.
        if args.contains("-reportPicker") {
            Task {
                await Task.pause(seconds: 3)
                if let coordinate = env.location.currentCoordinate ?? map.mapCenter {
                    withMotion { reportPoint = MapPoint(coordinate: coordinate) }
                }
            }
        }
        if args.contains("-quickToggles") {
            Task {
                await Task.pause(seconds: 2)
                withMotion { showQuickToggles = true }
            }
        }
        if args.contains("-askDriver") {
            Task {
                await Task.pause(seconds: 2)
                env.notifications.askDriverCheck()
            }
        }
        // Умная тишина: демо-история даёт спокойные проезды одних и тех же
        // камер, после пересчёта у них появляется галочка «своя».
        if args.contains("-demoFamiliar") {
            Task {
                await Task.pause(seconds: 2)
                // Камеру берём без бейджа «неточная»: у него приоритет на
                // плече маркера, и галочку «своя» он бы перекрыл.
                guard let coordinate = env.location.currentCoordinate,
                      let camera = env.cameras.nearest(to: coordinate, limit: 12)
                          .first(where: { !$0.isApproximate })
                else { return }
                env.trip.seedDemoFamiliar(cameraID: camera.id, at: camera.coordinate)
                env.location.refreshFamiliarCameras()
                map.focus(on: camera)
            }
        }
        // Карточка «Поездка сохранена» — поверх карты, с демо-историей.
        if args.contains("-demoTripEnd") {
            Task {
                await Task.pause(seconds: 2)
                env.trip.seedDemoHistory()
                if let record = env.trip.history.first {
                    withMotion(.spring(duration: 0.4)) { tripEndRecord = record }
                }
            }
        }
        // Краудсорс-доверие: призрак + подтверждённая отметка и «Что это было?»
        // локально — настоящий POST с симулятора лёг бы фейком в общую базу.
        if args.contains("-demoMobileTrust") {
            Task {
                await Task.pause(seconds: 2)
                if let center = map.mapCenter ?? env.location.currentCoordinate {
                    withMotion { env.mobile.seedTrustDemo(near: center) }
                }
            }
        }
        // Память о треногах: подписанного файла на симуляторе нет, а зоны на
        // карте увидеть надо — сеем две точки локально.
        if args.contains("-demoHotspots") {
            Task {
                await Task.pause(seconds: 2)
                if let center = map.mapCenter ?? env.location.currentCoordinate {
                    env.hotspots.seedDemo(near: center)
                    withMotion { map.invalidateVisible() }
                }
            }
        }
        // Бар точки долгого тапа: жест на симуляторе из CLI не сымитировать.
        if args.contains("-mapMenu") {
            Task {
                await Task.pause(seconds: 3)
                if let center = map.mapCenter ?? env.location.currentCoordinate {
                    selectPoint(at: center)
                }
            }
        }
        if args.contains("-demoRoute") {
            Task {
                await Task.pause(seconds: 2)
                buildRoute(to: CLLocationCoordinate2D(latitude: 41.3260, longitude: 69.2810),
                           name: "Демо-маршрут")
                if args.contains("-driveDemo") {
                    await Task.pause(seconds: 3)
                    if env.route.isActive {
                        env.location.startTrip()   // ориентацию поставит onChange
                    }
                    // Автозавершение поездки через N секунд: на симуляторе нет
                    // CoreMotion (автостоп не сработает) и нет тапов — а для
                    // проверки Итогов/шеринга нужна завершённая запись в истории.
                    if let idx = args.firstIndex(of: "-endTripAfter"),
                       let seconds = args.dropFirst(idx + 1).first.flatMap(Double.init) {
                        await Task.pause(seconds: seconds)
                        env.location.endTrip()
                    }
                }
            }
        }
    }
    #endif
}

// Изоляторы пер-тиковых чтений (OverspeedVignetteGate, ApproachOverlayGate,
// ManeuverBannerGate, DrivingHintChip, LocationFollowDriver) живут в
// MapTickGates.swift: они ЕДИНСТВЕННЫЕ читают то, что меняется каждый GPS-тик.
// Новое такое чтение добавляется туда, а не в body MapScreen.

/// Однострочная подсказка-капсула под HUD (см. OneTimeHints).
private struct HintChip: View {
    let text: String
    var tint: Color = Theme.accent

    var body: some View {
        Text(text)
            .font(.rounded(12, .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
