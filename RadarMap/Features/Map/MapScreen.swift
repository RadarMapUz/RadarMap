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
    // Умные кнопки: в поездке через 5 с бездействия интерфейс прячется, тап по карте возвращает.
    /// Режим «Спидометр» — тап по HUD (телефон в держателе).
    @State private var showDashboard = false
    /// Экранная модель своей схемы. Живёт всегда, а считается только когда
    /// схема действительно на экране: пустая модель не стоит ничего.
    @State private var sketch = SketchState()
    /// Нижняя кромка верхних панелей и верхняя кромка нижних, в пунктах окна.
    /// Меряют сами панели; схема переводит их в доли своей высоты.
    @State private var topPanelEdge: CGFloat = 0
    @State private var bottomPanelEdge: CGFloat = 0
    /// Спидометр закрыли руками в этой поездке — до её конца не навязываемся.
    /// Флаг живёт здесь, а не в настройках: это решение «сейчас», не «всегда».
    @State private var dashboardDismissedInTrip = false
    /// Разовая подсказка о жесте (см. OneTimeHints): максимум одна за запуск.
    @State private var activeHint: OneTimeHints.Hint?
    @State private var hintConsumedThisLaunch = false
    /// «Спидометр тратит меньше» — когда поездка началась на карте, батарея
    /// тает и зарядки нет.
    @State private var showBatterySaverHint = false
    /// Быстрые тумблеры оповещений (долгий тап по HUD).
    @State private var showQuickToggles = false
    /// Итог только что завершённой поездки («Поездка сохранена») и деталка из него.
    @State private var tripEndRecord: TripRecord?
    @State private var tripEndDetail: TripRecord?
    @Environment(\.scenePhase) private var scenePhase
    /// Пикер типа отметки (радар/тренога/пост/ДТП) для выбранной точки.
    @State private var reportPoint: MapPoint?
    /// Область карты для системных контролов MapKit. Своих в ней не осталось
    /// (компас убран), но scope нужен `Map(scope:)`.
    @Namespace private var mapScope

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

            // Панели знают, что под ними светлая карта: днём их фон плотнее,
            // иначе белые цифры на солнце тонут в стекле.
            topLayer
                .environment(\.onLightMap, scheme == .light)
            bottomLayer
                .environment(\.onLightMap, scheme == .light)

            // Превышение у камеры: свечение по краям. Отдельная вью: условие
            // читает скорость и дистанцию, меняющиеся каждый тик GPS, — в body
            // MapScreen это чтение пересобирало весь экран с картой ежесекундно.
            // Под приборкой не монтируем: у неё своя кромка, а пульсирующий
            // blur во весь экран крутился бы невидимым под крышкой.
            if !showDashboard {
                OverspeedVignetteGate()
            }

            // Следование за GPS: единственный подписчик locationTick.
            LocationFollowDriver(map: map, isCovered: showDashboard)
            // Схема считается ТОЛЬКО когда она на экране: тумблер выключен или
            // стоим — модель пуста и не стоит ни одного тика.
            if env.settings.mapBase == .sketch && !showDashboard {
                SketchRefreshDriver(sketch: sketch)
            }
            MobilePassDriver()
        }
        .mapScope(mapScope)
        .fullScreenCover(isPresented: $showDashboard) { DashboardView() }
        .task {
            map.configure(env.cameras, speedLimits: env.speedLimits, thermal: env.thermal,
                          hotspots: env.hotspots)
            map.filter = env.settings.filter
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
                              onRoute: env.location.currentCoordinate == nil ? nil : {
                                  buildRoute(to: camera.coordinate, name: camera.displayTitle)
                              })
        }
        .sheet(isPresented: $map.showNearbySheet) {
            NearbyCamerasSheet(onSelect: { map.focus(on: $0) })
        }
        .sheet(isPresented: $map.showSearch) {
            // Без геопозиции кнопки маршрута прячем, как в соседних шитах:
            // мёртвая кнопка, молча закрывающая поиск, хуже её отсутствия.
            SearchView(onSelect: { map.move(to: $0) },
                       onRoute: env.location.currentCoordinate == nil ? nil
                           : { coord, name in buildRoute(to: coord, name: name) })
        }
        .sheet(isPresented: $showRouteCameras) {
            RouteCamerasSheet(onSelect: { map.focus(on: $0) })
        }
        .sheet(isPresented: $map.showSettings) { SettingsView() }
        .sheet(isPresented: $map.showStats) {
            TripStatsSheet(onRoute: env.location.currentCoordinate == nil ? nil : { coord, name in
                buildRoute(to: coord, name: name)
            })
        }
        // Деталка из карточки «Поездка сохранена» — без захода в Итоги.
        .sheet(item: $tripEndDetail) { record in
            TripDetailSheet(record: record,
                            onRoute: env.location.currentCoordinate == nil ? nil : { coord, name in
                buildRoute(to: coord, name: name)
            })
        }
        .overlay { loadErrorOverlay }
        .overlay { approachOverlay }
        .overlay { arrivalOverlay }
        // Пуш «Итоги поездки» и другие диплинки на статистику ведут сюда.
        .onOpenURL { url in
            guard url.scheme == "radarmap", url.host() == "trip" else { return }
            // Поверх может быть другой шит — вторая презентация молча не
            // проходит, а «истинный» showStats делал кнопку Итогов мёртвой.
            // Закрываем всё своё и открываем Итоги после паузы на анимацию.
            map.selectedCamera = nil
            map.showNearbySheet = false
            map.showSearch = false
            map.showSettings = false
            showRouteCameras = false
            showDashboard = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                map.showStats = true
            }
        }
        .onChange(of: env.location.nearestCamera?.id) { _, _ in
            dismissedApproachID = nil   // новая ближайшая камера — снова показываем предупреждение
        }
        // Проезд чужой передвижной отметки живёт в MobilePassDriver
        // (MapTickGates): onChange(locationTick) прямо здесь делал весь body
        // зависимым от тика — второй подписчик в обход правила изоляторов.
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
                withAnimation { tripEndRecord = nil }   // поехали снова — старый итог не актуален
                // Поездка = спидометр: он строился ради батареи (чёрный OLED и
                // растр вместо тайлов с двумя сотнями маркеров), но был
                // секретным экраном за тапом по HUD. Открываем сами — если
                // пользователь не отключил это в настройках И если накрывать
                // нечем.
                //
                // Вторая половина условия — вот в чём дело. Спидометр это
                // fullScreenCover: открываясь сам, он накрывает ВЕСЬ режим
                // движения. Пока карту рисовала Apple, потеря была небольшой.
                // Но человек, выбравший свою схему или движок, выбрал именно
                // КАРТУ ЗА РУЛЁМ — и накрывать её крышкой значит отменять его
                // выбор ровно в тот момент, когда он должен сработать.
                //
                // Это и есть корень жалобы «переключил, а ничего не
                // изменилось»: схема требовала одновременно поездки и
                // закрытого спидометра, а поездка сама его открывала.
                if env.settings.dashboardAutoOpens, env.settings.mapBase == .apple {
                    showDashboard = true
                } else {
                    // Спидометр не откроется сам — самое время для подсказок:
                    // про жёлтую кнопку (она видна только в поездке) и про
                    // экономию, если батарея тает без зарядки.
                    maybeShowHint()
                    maybeSuggestDashboardForBattery()
                }
            } else {
                dashboardDismissedInTrip = false   // новая поездка — с чистого листа
                showDashboard = false              // поездка кончилась — спидометр не нужен
                maybeShowTripEnd()
            }
        }
        // Закрыли спидометр руками во время поездки — запоминаем и до её конца
        // не открываем сами: автопереход не должен спорить с человеком.
        .onChange(of: showDashboard) { _, shown in
            if !shown, env.location.isTripActive { dashboardDismissedInTrip = true }
        }
    }

    @ViewBuilder private var arrivalOverlay: some View {
        if let arrival = env.route.lastArrival {
            ArrivalCardView(arrival: arrival, onDismiss: { env.route.dismissArrival() })
                .transition(.opacity)
        }
    }

    @ViewBuilder private var approachOverlay: some View {
        // Под приборкой не монтируем вовсе: она показывает камеру сама, а
        // полноэкранный алерт с вечным пульсом рисовался и диффился невидимым.
        if showDashboard {
            EmptyView()
        } else {
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
        sketch.setPanelEdges(top: topPanelEdge, bottom: bottomPanelEdge)
    }

    /// Подложка экрана: своя схема или карта Apple.
    ///
    /// Отдельным свойством, а не `if` внутри стопки: тело MapScreen и без
    /// того на пределе — компилятор перестал его выводить за разумное время,
    /// как только развилка встала прямо в ZStack.
    /// Что рисует карту прямо сейчас. Решает ВЫБОР ЧЕЛОВЕКА, а не режим:
    /// правило целиком в `MapBase.resolved` и покрыто тестами.
    private var shownBase: MapBase {
        MapBase.resolved(chosen: env.settings.mapBase,
                         isAddingCamera: map.isAddingCamera,
                         hasPressedPoint: map.pressedPoint != nil,
                         sketchReady: !showDashboard && sketch.scene?.isEmpty == false,
                         engineAvailable: !showDashboard && Self.engineAvailable)
    }

    /// Есть ли в сборке движок. Пакета может не быть — тогда его нет и в
    /// списке подложек, а не «есть, но молча не работает».
    static var engineAvailable: Bool {
        #if canImport(MapLibre)
        return true
        #else
        return false
        #endif
    }

    static var availableBases: [MapBase] {
        MapBase.allCases.filter { $0 != .engine || engineAvailable }
    }

    @ViewBuilder
    /// Подложка. Сам этот кусок body НЕ читает ничего, что пишется на тике:
    /// обе свои карты вынесены отдельными вью (MapBaseLayers), и чтение
    /// скорости, дистанции и координаты заперто внутри них. Пока они лежали
    /// здесь, включённая своя схема пересобирала весь экран раз в секунду.
    @ViewBuilder
    private func baseLayer(scheme: ColorScheme) -> some View {
        switch shownBase {
        case .engine:
            #if canImport(MapLibre)
            // Карту рисует движок. Панели поверх — те же: они про скорость и
            // камеры, а не про подложку.
            EngineBaseLayer(state: sketch).ignoresSafeArea()
            #else
            mapLayer.ignoresSafeArea().environment(\.colorScheme, scheme)
            #endif
        case .sketch:
            if let scene = sketch.scene {
                SketchBaseLayer(scene: scene, state: sketch)
            } else {
                mapLayer.ignoresSafeArea().environment(\.colorScheme, scheme)
            }
        case .apple:
            mapLayer
                .ignoresSafeArea()
                .environment(\.colorScheme, scheme)
        }
    }

    private var mapLayer: some View {
        MapReader { proxy in
            mapContent
                // Долгий тап → точка с баром действий. Sequenced-хак: LongPress
                // не отдаёт координату, добираем её нулевым DragGesture.
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.45)
                        .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                        .onEnded { value in
                            guard case .second(true, let drag) = value,
                                  let location = drag?.location,
                                  let coordinate = proxy.convert(location, from: .local) else { return }
                            selectPoint(at: coordinate)
                        }
                )
        }
    }

    /// Места на подложке. Полностью стерильная карта мертва: ни заправки, ни
    /// больницы — то есть ровно того, ради чего карту и открывают.
    ///
    /// Раньше в поездке места гасились ПРИНУДИТЕЛЬНО, независимо от тумблера,
    /// а рядом подписывалось «в поездке места скрыты». Это тот же порок, что и
    /// подложка, включавшаяся только после старта поездки: настройка есть,
    /// человек её тронул, а приложение решило за него. Заправка нужна как раз
    /// в дороге — тумблер значит ровно то, что на нём написано.
    private var pointsOfInterest: PointOfInterestCategories {
        guard env.settings.mapPlaces else { return .excludingAll }
        return .including([.gasStation, .parking, .hospital, .pharmacy, .police])
    }

    private var mapContent: some View {
        Map(position: $map.position, scope: mapScope) {
            UserAnnotation()

            // Маршрут: сперва тусклые альтернативы, поверх — выбранный вариант
            // (тёмная подложка + неоновая линия, читается на любом фоне).
            if !env.location.isTripActive {
                ForEach(env.route.variants) { variant in
                    if variant.id != env.route.selectedID {
                        MapPolyline(variant.polyline)
                            .stroke(Theme.textTertiary,
                                    style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            if let polyline = env.route.polyline {
                MapPolyline(polyline)
                    .stroke(Theme.background.opacity(0.85),
                            style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                MapPolyline(polyline)
                    .stroke(LinearGradient(colors: [Theme.accent, Theme.Types.intelligent],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                // Пройденная часть тускнеет — видно, сколько осталось.
                if env.location.isTripActive, let traveled = env.route.traveledPolyline {
                    MapPolyline(traveled)
                        .stroke(Theme.textTertiary.opacity(0.7),
                                style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
            }
            if let dest = env.route.destinationCoordinate {
                Annotation(env.route.destinationName, coordinate: dest, anchor: .center) {
                    Image(systemName: "flag.checkered")
                        .font(.rounded(14, .bold))
                        .foregroundStyle(Theme.background)
                        .frame(width: 32, height: 32)
                        .background(Theme.accent.gradient, in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
                }
                .annotationTitles(.hidden)
            }

            // Память о треногах — НЕ камеры и рисуются не как камеры: мягкая
            // зона без значка и без клина. Кружок-камера здесь означал бы «тут
            // прибор», а прибора может не быть — есть привычка его ставить.
            // Только на близком зуме: на обзорном это шум поверх настоящих
            // точек, а решение сбросить скорость принимают вблизи.
            if env.settings.tripodHints, !map.isDotZoom {
                ForEach(map.visibleHotspots, id: \.key) { spot in
                    MapCircle(center: spot.coordinate, radius: AppConfig.hotspotZoneRadiusMeters)
                        .foregroundStyle(Theme.Types.radar.opacity(0.10))
                        .stroke(Theme.Types.radar.opacity(0.5),
                                style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                }
            }

            // Важность считается один раз на пересборку: id цели и камеры
            // маршрута меняются редко, точка отсчёта троттлится по 300 м.
            // Набор камер маршрута берём готовым: собирать его здесь значило
            // строить Set заново на каждую пересборку слоя.
            let targetID = env.location.nearestCamera?.id
            let routeIDs = env.route.routeCameraIDs
            // Множество читается один раз на сборку слоя, а не на маркер:
            // оно меняется раз в поездку, а маркеров на экране до двух сотен.
            let familiarIDs = env.location.familiarCameraIDs
            ForEach(map.visibleCameras) { camera in
                Annotation(camera.displayTitle, coordinate: camera.coordinate, anchor: .center) {
                    // Средний зум: точки; близкий — мини-знак лимита («60»);
                    // полный пин — у выбранной и ближайшей по курсу.
                    CameraAnnotationView(
                        camera: camera,
                        selected: map.highlightedID == camera.id,
                        compact: map.isDotZoom && camera.id != targetID,
                        // Лимит из слоя, а не из спатиал-индекса: 220 запросов
                        // на каждую перерисовку карты — это и был один из лагов.
                        limit: map.isDotZoom ? nil : map.visibleLimits[camera.id],
                        tier: CameraMapContent.tier(camera: camera, focus: map.focus,
                                                    targetID: targetID, routeIDs: routeIDs),
                        mapHeading: map.mapHeading,
                        isFamiliar: familiarIDs.contains(camera.id)
                    )
                    .onTapGesture { map.select(camera) }
                }
                .annotationTitles(.hidden)
            }
            ForEach(map.clusters) { cluster in
                Annotation("\(cluster.count)", coordinate: cluster.coordinate, anchor: .center) {
                    ClusterAnnotationView(count: cluster.count)
                        .onTapGesture { map.zoomInto(cluster) }
                }
                .annotationTitles(.hidden)
            }

            // Точка долгого тапа — пульсирующий маркер, пока открыт бар действий.
            if let point = map.pressedPoint {
                Annotation("", coordinate: point.coordinate, anchor: .center) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.rounded(26, .bold))
                        .foregroundStyle(Theme.background, Theme.accent)
                        .shadow(color: Theme.accent.opacity(0.6), radius: 8)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: pointsOfInterest,
                            showsTraffic: env.settings.mapTraffic))
        // Системный компас убран совсем: при севере вверху он не значит ничего,
        // а при повороте его роль берёт третье состояние MapOrientationControl.
        .mapControls {}
        .onMapCameraChange(frequency: .onEnd) { context in
            map.updateVisible(for: context.region)
            // Поворот карты руками (двухпалый жест): клин направления должен
            // знать актуальный угол. В compass-follow сюда не попадаем — там
            // heading уже честно nil.
            if !map.followsDeviceHeading { map.setMapHeading(context.camera.heading) }
        }
        // Любое касание карты будит спрятанные кнопки (не мешая тапам по маркерам)
        // и закрывает бар точки долгого тапа.
        .simultaneousGesture(TapGesture().onEnded {
            if map.pressedPoint != nil {
                withAnimation(.spring(duration: 0.3)) { map.pressedPoint = nil }
            }
        })
        // Потянул карту рукой — слежение снимается. Именно жест, а не
        // onMapCameraChange: тот срабатывает и на собственные анимации следования,
        // и режим «по ходу движения» гасил бы сам себя на каждом кадре.
        .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in
            map.releaseOrientation()
        })
    }

    // MARK: - Разовые подсказки

    /// Показать следующую невиданную подсказку (максимум одну за запуск).
    /// Решение «какую» — чистый OneTimeHints; здесь только Storage и таймер.
    private func maybeShowHint() {
        guard Storage.bool(.hasCompletedOnboarding), !hintConsumedThisLaunch,
              activeHint == nil, !map.isAddingCamera, !showDashboard else { return }
        var shown: Set<OneTimeHints.Hint> = []
        if Storage.bool(.hintDashboardShown) { shown.insert(.dashboard) }
        if Storage.bool(.hintTogglesShown) { shown.insert(.toggles) }
        if Storage.bool(.hintRadarShown) { shown.insert(.radar) }
        if Storage.bool(.hintSilenceShown) { shown.insert(.smartSilence) }
        guard let hint = OneTimeHints.next(
            shown: shown,
            radarVisible: mode.showsReportButton,
            hasFamiliarCameras: !env.location.familiarCameraIDs.isEmpty) else { return }
        hintConsumedThisLaunch = true
        switch hint {
        case .dashboard: Storage.set(true, for: .hintDashboardShown)
        case .toggles:   Storage.set(true, for: .hintTogglesShown)
        case .radar:     Storage.set(true, for: .hintRadarShown)
        case .smartSilence: Storage.set(true, for: .hintSilenceShown)
        }
        withAnimation(.spring(duration: 0.3)) { activeHint = hint }
        Task {
            await Task.pause(seconds: 7)
            withAnimation(.easeOut(duration: 0.3)) { activeHint = nil }
        }
    }

    /// «Спидометр тратит меньше»: поездка началась на карте (автопереход
    /// выключен), зарядки нет, батарея ниже трети. Мониторинг батареи
    /// включается на один замер и тут же гасится — держать его постоянно ради
    /// подсказки было бы иронией на тему экономии.
    private func maybeSuggestDashboardForBattery() {
        let battery = BatteryProbe.snapshot()
        guard let percent = battery.percent, percent < 30, !battery.isCharging else { return }
        withAnimation(.spring(duration: 0.3)) { showBatterySaverHint = true }
        Task {
            await Task.pause(seconds: 8)
            withAnimation(.easeOut(duration: 0.3)) { showBatterySaverHint = false }
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
            // Почему приложение работает не в полную силу: объявление сервера,
            // серая карта без сети, урезанная карта в жару, отсутствие лимитов.
            // Выше всего, потому что человек должен узнать причину раньше, чем
            // упрётся в неё сам и решит, что приложение сломалось.
            MapStatusBanner(onOpenDashboard: { showDashboard = true })
            // Доступ к геопозиции — сразу под объявлениями сервера, а не внизу
            // поверх карты: это причина, по которой приложение не предупреждает
            // в фоне, и место ей рядом с остальными «почему не в полную силу».
            permissionBanner
            // Тап по HUD — «Спидометр»; долгий тап — быстрые тумблеры оповещений.
            // В навигации главный элемент — манёвр, поэтому HUD уходит на
            // второй план: одного «главного» на экране достаточно, два спорят
            // за взгляд (MapMode.focus).
            SpeedHUDView(secondary: mode.focus != .speed)
                .onTapGesture { showDashboard = true }
                .onLongPressGesture(minimumDuration: 0.4) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.spring(duration: 0.3)) { showQuickToggles.toggle() }
                }
                // Жесты для VoiceOver не существуют — даём оба входа действиями.
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(Text("Открывает спидометр"))
                .accessibilityAction(named: Text("Спидометр")) { showDashboard = true }
                .accessibilityAction(named: Text("Быстрые тумблеры")) {
                    withAnimation(.spring(duration: 0.3)) { showQuickToggles.toggle() }
                }
            // Разовые подсказки по жестам и экономии — по одной, не простынёй.
            if let hint = activeHint {
                HintChip(text: hint.text)
            }
            if showBatterySaverHint {
                HintChip(text: String(localized: "Спидометр тратит меньше — тап по скорости"),
                         tint: Theme.success)
            }
            // «Я в такси»: приложение молчит осознанно — человек должен видеть,
            // почему нет оповещений, и уметь передумать одним тапом.
            if env.location.isPassengerSession {
                passengerChip
            }
            // Turn-by-turn: ближайший манёвр — в поездке по маршруту.
            // Отдельная вью: дистанция до манёвра меняется каждый тик GPS.
            ManeuverBannerGate()
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
                    withAnimation(.spring(duration: 0.3)) { showQuickToggles = false }
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
                }
            // Кнопки навигации — сразу под HUD справа. Не прячутся: см. controlColumn.
            if !map.isAddingCamera {
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
            .padding(.vertical, 10)
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
            // Слои карты — первой в колонке и в ЛЮБОМ режиме.
            //
            // Подложка лежала в десятом разделе настроек и включалась только
            // после старта поездки; пробки и места жили в отдельной панели,
            // которой в поездке не бывало вовсе. Теперь это одна панель, и она
            // на месте всегда.
            MapLayersControl(base: Binding(get: { env.settings.mapBase },
                                           set: { env.settings.mapBase = $0 }),
                             traffic: Binding(get: { env.settings.mapTraffic },
                                              set: { env.settings.mapTraffic = $0 }),
                             places: Binding(get: { env.settings.mapPlaces },
                                             set: { env.settings.mapPlaces = $0 }),
                             houses: Binding(get: { env.settings.mapHouses },
                                             set: { env.settings.mapHouses = $0 }),
                             sidewalks: Binding(get: { env.settings.mapSidewalks },
                                                set: { env.settings.mapSidewalks = $0 }),
                             showsBuildingLayers: shownBase != .apple,
                             available: Self.availableBases,
                             showsLegend: shownBase == .apple)
            MapOrientationControl(orientation: map.orientation) {
                map.cycleOrientation(coordinate: env.location.currentCoordinate,
                                     course: env.location.currentCourse,
                                     inTrip: env.location.isTripActive)
            }
            // Жёлтой кнопки «Радар здесь» здесь БОЛЬШЕ НЕТ, и это не потеря.
            //
            // В поездке их было две, обе жёлтые, обе на одном экране — и
            // поведение разное: эта открывала выбор типа из четырёх плиток,
            // а квадратная в панели поездки отправляла сразу и потом шесть
            // секунд предлагала уточнить. Один и тот же жест давал два исхода
            // в зависимости от того, в какой угол попал палец; за рулём это
            // гарантированная ошибка.
            //
            // Осталась та, что быстрее: отправка одним тапом с последующим
            // уточнением. Выбор типа никуда не делся — он в уточнении и в
            // долгом тапе по карте.
            // Спидометр — здесь же, а не отдельной пилюлей над панелью
            // поездки. Пилюля была четвёртой формой на экране (карточка,
            // круглые кнопки, капсула, панель) и висела в пустоте у нижнего
            // края; дверь на приборку от переезда в общую колонку не
            // пропадает, а экран перестаёт говорить четырьмя голосами.
            if mode.showsTripBar {
                CircleControl(systemName: "gauge.with.needle", tint: Theme.textPrimary,
                              accessibilityLabel: "Открыть спидометр") {
                    showDashboard = true
                }
                .transition(.scale.combined(with: .opacity))
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
            if mode.showsTripBar {
                Menu {
                    tripActionItems
                } label: {
                    CircleControlFace(systemName: "ellipsis")
                }
                .accessibilityLabel(Text("Ещё"))
                .transition(.scale.combined(with: .opacity))
            }
            // Зум — щипком, как в Apple Maps: кнопки только занимали место.
        }
        .animation(.spring(duration: 0.3), value: mode.showsTripBar)
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
                    onRoute: env.location.currentCoordinate == nil ? nil : {
                        buildRoute(to: point.coordinate, name: String(localized: "Точка на карте"))
                        withAnimation { map.pressedPoint = nil }
                    },
                    onRadar: {
                        withAnimation {
                            map.pressedPoint = nil
                            reportPoint = point   // дальше — выбор типа отметки
                        }
                    },
                    onOwnCamera: {
                        // Крестик режима добавления встаёт на выбранную точку —
                        // пользователь при желании доводит позицию вручную.
                        withAnimation {
                            map.pressedPoint = nil
                            map.position = .region(MKCoordinateRegion(
                                center: point.coordinate,
                                latitudinalMeters: 500, longitudinalMeters: 500))
                            map.isAddingCamera = true
                        }
                    },
                    onCancel: {
                        withAnimation { map.pressedPoint = nil }
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
                        withAnimation { reportPoint = nil }
                    },
                    onCancel: { withAnimation { reportPoint = nil } }
                )
            } else {
                // «Радар ещё стоял?» — над панелью поездки: вопрос живёт
                // двадцать секунд и уходит сам, ничего не отправляя. Пока на
                // экране предупреждение о камере, вопрос ждёт: камера важнее,
                // а под оверлеем плашка сгорала невидимой.
                // Ждёт и под предупреждением о камере, и под приборкой: там
                // вопрос рисует она сама, а два живых таймера — двойной ответ.
                // Условие «накрыто» — в гейте: isApproachingCamera читает
                // пер-тиковые дистанцию и скорость (см. MapTickGates).
                MobileConfirmGate(dashboardShown: showDashboard)
                // «Что это было?» — уточнение типа сразу после «Радар!»:
                // тот же гейт-паттерн и то же место над панелью поездки.
                ReportRefineGate(dashboardShown: showDashboard)
                // Итог поездки — сразу после стопа, в момент, когда цифры
                // интереснее всего (см. maybeShowTripEnd про условия показа).
                if let record = tripEndRecord {
                    TripEndCard(
                        record: record,
                        onDetail: { chosen in
                            withAnimation(.spring(duration: 0.3)) { tripEndRecord = nil }
                            tripEndDetail = chosen
                        },
                        onMerged: { tripEndRecord = env.trip.history.first },
                        onDismiss: {
                            withAnimation(.spring(duration: 0.3)) { tripEndRecord = nil }
                        })
                }
                if mode.showsTripBar {
                    // В поездке: компактная строка (прибытие · остаток · камера · стоп) —
                    // максимум экрана отдан карте, и она не прячется вместе с кнопками.
                    TripLiveBar(
                        onShowCameras: { showRouteCameras = true },
                        onStop: { toggleTrip() }
                    )
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
                        Text(error)
                            .font(.rounded(12, .medium)).foregroundStyle(Theme.danger)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .onTapGesture { env.route.clear() }
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
        }
    }

    private var bottomLayer: some View {
        VStack(spacing: 10) {
            Spacer()
            bottomPanels
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: {
                    bottomPanelEdge = $0 - 8
                    applySketchInsets()
                }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.spring(duration: 0.3), value: map.isAddingCamera)
        .animation(.spring(duration: 0.3), value: map.pressedPoint)
        .animation(.spring(duration: 0.3), value: reportPoint)
    }

    /// Долгий тап: маркер + бар действий (кроме режима прицела добавления камеры).
    private func selectPoint(at coordinate: CLLocationCoordinate2D) {
        guard !map.isAddingCamera else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.spring(duration: 0.3)) {
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
        guard scenePhase == .active, !map.showStats,
              let record = env.trip.history.first,
              Date().timeIntervalSince(record.endedAt) < 60 else { return }
        withAnimation(.spring(duration: 0.4)) { tripEndRecord = record }
    }

    /// Построить авто-маршрут от текущей позиции и показать все варианты целиком.
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
            if !rect.isNull {
                // Показываем маршрут целиком — это уже не слежение за точкой.
                map.releaseOrientation()
                let padded = rect.insetBy(dx: -rect.width * 0.18, dy: -rect.height * 0.18)
                withAnimation(.easeInOut(duration: 0.5)) {
                    map.position = .rect(padded)
                }
                map.updateVisible(for: MKCoordinateRegion(padded))
            }
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
            .padding(.vertical, 9)
            .background(Theme.surface, in: Capsule())
        }
        .buttonStyle(PressableStyle())
    }

    /// CTA: градиент со световой кромкой сверху и двойной тенью — премиальный
    /// объём, высота 52 в линию с кругами Дом/Работа. Остаётся тем, у кого
    /// автостарт выключен: без нажатия поездки не будет вовсе.
    private var tripButtonPrimary: some View {
        Button {
            toggleTrip()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                Text("Начать поездку")
            }
            .font(.rounded(16, .bold))
            .foregroundStyle(Theme.background)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                LinearGradient(colors: [Theme.success.opacity(0.98), Theme.success.opacity(0.72)],
                               startPoint: .top, endPoint: .bottom), in: Capsule())
            .overlay(Capsule().strokeBorder(
                LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.03)],
                               startPoint: .top, endPoint: .bottom), lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
        .shadow(color: Theme.success.opacity(0.35), radius: 14, y: 5)
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    }

    /// Док действий: стекло со световой кромкой и глубокая тень — в одном
    /// языке с CTA и кругами (премиальный низ экрана без разнобоя).
    /// Четыре постоянных действия — больше глазу не нужно. Редкое «добавить
    /// свою камеру» живёт в меню «Ещё»: оно нужно раз в месяц, а место в баре
    /// занимало всегда (plan_main_screen.md, шаг 4).
    private var actionBar: some View {
        HStack(spacing: 4) {
            actionButton("Поиск", "magnifyingglass") { map.showSearch = true }
            actionButton("Рядом", "list.bullet") { map.showNearbySheet = true }
            actionButton("Итоги", "chart.bar.fill") { map.showStats = true }
            Menu {
                moreActionItems
            } label: {
                actionLabel("Ещё", "ellipsis.circle.fill")
            }
            .accessibilityLabel(Text("Ещё"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .backport.glassEffect(.regular, in: .rect(cornerRadius: Theme.cornerPanel))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous)
            .strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
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
        Button { map.showNearbySheet = true } label: {
            Label("Рядом", systemImage: "list.bullet")
        }
        Button { map.showStats = true } label: {
            Label("Итоги", systemImage: "chart.bar.fill")
        }
        moreActionItems
    }

    /// Редкое: в баре место занимало бы всегда, а нужно раз в месяц.
    @ViewBuilder private var moreActionItems: some View {
        Button {
            withAnimation { map.isAddingCamera = true }
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
                Button(banner.button, action: banner.action)
                    .font(.rounded(12, .semibold)).foregroundStyle(Theme.accent)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
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
            withAnimation { map.isAddingCamera = false }
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
        withAnimation { map.isAddingCamera = false }
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
        // Демо-история двухнедельной давности: проверка «в этом периоде поездок нет».
        if args.contains("-demoHistoryOld") { env.trip.seedDemoHistory(shiftDays: 14) }
        if args.contains("-showStats") { map.showStats = true }
        if args.contains("-showSettings") { map.showSettings = true }
        // Приборку на симуляторе иначе не снять: её открывают тапом по HUD,
        // а он перекрыт кнопкой поездки в скриншот-прогонах.
        if args.contains("-showDashboard") { showDashboard = true }
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
                withAnimation(.easeInOut(duration: 0.6)) {
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
                    withAnimation { reportPoint = MapPoint(coordinate: coordinate) }
                }
            }
        }
        if args.contains("-quickToggles") {
            Task {
                await Task.pause(seconds: 2)
                withAnimation { showQuickToggles = true }
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
                    withAnimation(.spring(duration: 0.4)) { tripEndRecord = record }
                }
            }
        }
        // Краудсорс-доверие: призрак + подтверждённая отметка и «Что это было?»
        // локально — настоящий POST с симулятора лёг бы фейком в общую базу.
        if args.contains("-demoMobileTrust") {
            Task {
                await Task.pause(seconds: 2)
                if let center = map.mapCenter ?? env.location.currentCoordinate {
                    withAnimation { env.mobile.seedTrustDemo(near: center) }
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
                    withAnimation { map.invalidateVisible() }
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
