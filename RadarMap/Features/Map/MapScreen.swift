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
    @Environment(AppEnvironment.self) var env
    @State var map = MapState()
    @State var dismissedApproachID: Int?
    @State var showRouteCameras = false
    /// «Мои места» из нижнего бара: Дом, Работа, недавние — маршрут в один тап.
    @State var showMyPlaces = false
    /// Экранная модель своей схемы. Живёт всегда, а считается только когда
    /// схема действительно на экране: пустая модель не стоит ничего.
    /// Поля вида (отступы панелей и якорь машины) — их читает наша карта.
    /// Имя историческое: модель заводилась под самодельную схему, а осталась
    /// от неё только геометрия вида, которой пользуется движок.
    @State var frame = MapFrameState()
    /// Нижняя кромка верхних панелей и верхняя кромка нижних, в пунктах окна.
    /// Меряют сами панели; схема переводит их в доли своей высоты.
    @State var topPanelEdge: CGFloat = 0
    @State var bottomPanelEdge: CGFloat = 0
    /// Верх нижней карточки предупреждения о камере (в навигации), nil — нет.
    @State var alertCardEdge: CGFloat?
    /// Сколько кнопок помещается в колонку справа (TripScreenLayout.columnSlots).
    /// Отдельно от кромок и только при смене: кромки body не читает, а это
    /// число — читает, и писать его на каждый пиксель высоты панели значило
    /// бы пересобирать весь экран с картой (Perf.mapBody).
    @State var columnSlots: Int?
    /// Разовая подсказка о жесте (см. OneTimeHints): максимум одна за запуск.
    @State var activeHint: OneTimeHints.Hint?
    /// «Что нового» после обновления (WhatsNew) — среди листов карты, чтобы
    /// диплинк виджета закрывал его вместе с остальными.
    @State var showsWhatsNew = false
    @State var hintConsumedThisLaunch = false
    /// «Батарея садится — погасите экран»: поездка началась, заряд тает, а
    /// зарядки нет.
    @State var showBatterySaverHint = false
    /// Быстрые тумблеры оповещений (тап по HUD).
    @State var showQuickToggles = false
    /// Итог только что завершённой поездки («Поездка сохранена») и деталка из него.
    @State var tripEndRecord: TripRecord?
    @State var tripEndDetail: TripRecord?
    /// Текст ссылки «Поделиться прибытием» для системного листа.
    @State var etaSharePayload: ActivityTextPayload?
    @Environment(\.scenePhase) var scenePhase
    /// Пикер типа отметки (радар/тренога/пост/ДТП) для выбранной точки.
    @State var reportPoint: MapPoint?
    /// Область карты для системных контролов MapKit. Своих в ней не осталось
    /// (компас убран), но scope нужен `Map(scope:)`.

    /// Что нужно водителю прямо сейчас: правила видимости — в MapMode,
    /// а не россыпью условий по вёрстке (см. MapMode.swift).
    var mode: MapMode {
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
            // Скриншот-хук: `-demoGhost [late|tight|ok]` — строка «Работа · 9:12 ·
            // +4 мин»; со словом — с запасом до срока «быть к».
            let arguments = ProcessInfo.processInfo.arguments
            if let at = arguments.firstIndex(of: "-demoGhost") {
                let mode = arguments.indices.contains(at + 1) ? arguments[at + 1] : ""
                Task {
                    await Task.pause(seconds: 4)
                    let arrival = Date().addingTimeInterval(22 * 60)
                    let minutes = ["late": -7, "tight": 3, "ok": 9][mode]
                    let slack = minutes.map {
                        CommuteGhost.TargetSlack(state: .raw(minutes: Double($0)), minutes: $0,
                                                 deadline: arrival.addingTimeInterval(Double($0) * 60))
                    }
                    env.commuteLive.showDemo(direction: .toWork, arrival: arrival, deltaMinutes: 4, slack: slack)
                }
            }
            // Скриншот-хук: `-whatsNew` — показать «Что нового» снова.
            if ProcessInfo.processInfo.arguments.contains("-whatsNew") {
                Storage.set(0, for: .whatsNewEdition)
            }
            #endif
            // Подсказка о жесте — после того как карта обжилась: чип поверх
            // стартовой анимации читается как сбой, а не как помощь.
            Task {
                await Task.pause(seconds: 3)
                // «Что нового» — вместо разовой подсказки, а не поверх неё:
                // подсказка под листом сгорела бы, а у обновившихся она одна
                // на всю жизнь (ревью 19.10).
                if !maybeShowWhatsNew() { maybeShowHint() }
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
            // карта; region-мониторинг пересобирает AppEnvironment.
            map.invalidateVisible()
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
                           withMotion(Motion.standard) {
                               map.pressedPoint = MapPoint(coordinate: coordinate, title: title)
                           }
                       },
                       onRoute: !env.location.hasLocation ? nil
                           : { coord, name in buildRoute(to: coord, name: name) },
                       onAddStop: !env.location.hasLocation || !env.route.isActive ? nil
                           : { coord, name in addStop(coord, name: name) })
        }
        .sheet(isPresented: $showsWhatsNew) { WhatsNewSheet() }
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
                              withMotion(Motion.standard) {
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
        // «Поделиться прибытием»: ссылка начинает обновляться, только если
        // её действительно отправили.
        .sheet(item: $etaSharePayload) { payload in
            ActivityTextSheet(text: payload.text) { sent in
                sent ? env.etaShare.confirmShared() : env.etaShare.cancelPrepared()
            }
            .presentationDetents([.medium, .large])
        }
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
        // Диплинки на статистику (DeepLink.parse):
        // radarmap://trip/<id> — пуш «Итоги поездки», открывает ЭТУ поездку;
        // radarmap://trip — виджет недели на локскрине,
        // radarmap://stats — домашний виджет километров.
        .onOpenURL { url in
            guard let link = DeepLink.parse(url) else { return }
            // Поверх может быть другой шит — вторая презентация молча не
            // проходит, а «истинный» showStats делал кнопку Итогов мёртвой.
            // Закрываем всё своё и открываем Итоги после паузы на анимацию.
            map.selectedCamera = nil
            map.showNearbySheet = false
            map.showSearch = false
            map.showSettings = false
            showRouteCameras = false
            showMyPlaces = false
            showsWhatsNew = false
            tripEndDetail = nil
            // Деталка — отдельный шит карты: поверх открытых Итогов не встанет.
            if link != .stats { map.showStats = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                switch link {
                case .stats:
                    map.showStats = true
                case .trip(let id):
                    // Записи нет (склеена, стёрта) — обзор лучше пустого экрана.
                    if let record = env.trip.history.first(where: { $0.id == id }) {
                        tripEndDetail = record
                    } else {
                        map.showStats = true
                    }
                case .lastTrip:
                    if let last = env.trip.history.first { tripEndDetail = last } else { map.showStats = true }
                }
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

    // MARK: - Карта

    /// Тема подложки: авто — по СОЛНЦУ в точке пользователя, не по будильнику.
    /// Прежние часы 6–19 врали дважды в год по часу: в декабре в 18:30 темно,
    /// а карта слепила белым. Без координаты — прежнее грубое правило (Sun).
    var mapColorScheme: ColorScheme {
        switch env.settings.mapAppearance {
        case .dark:  return .dark
        case .light: return .light
        case .auto:
            // Тот же день/ночь, что у интерфейса и CarPlay (AppEnvironment,
            // раз в 5 мин): не NOAA-расчёт в body и не своя точка.
            return env.interfaceIsDaylight ? .light : .dark
        }
    }

    /// Отдать схеме измеренные кромки панелей.
    ///
    /// Одной точкой, а не двумя вызовами из двух замеров: поля приходят
    /// парой, и половина пары — это неверная проекция на один кадр.
    func applySketchInsets() {
        frame.setPanelEdges(top: topPanelEdge,
                            bottom: MapFrameState.bottomEdge(panel: bottomPanelEdge, overlay: alertCardEdge))
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
    func baseLayer(scheme: ColorScheme) -> some View {
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
    func mapBase(scheme: ColorScheme) -> some View {
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

}

// Изоляторы пер-тиковых чтений (OverspeedVignetteGate, ApproachOverlayGate,
// ManeuverBannerGate, DrivingHintChip, LocationFollowDriver) живут в
// MapTickGates.swift: они ЕДИНСТВЕННЫЕ читают то, что меняется каждый GPS-тик.
// Новое такое чтение добавляется туда, а не в body MapScreen.

/// Однострочная подсказка-капсула под HUD (см. OneTimeHints).
struct HintChip: View {
    let text: String
    var tint: Color = Theme.accent

    var body: some View {
        Text(text)
            .font(.rounded(12, .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .liftedBackground(Theme.surface, in: Capsule())
            .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
