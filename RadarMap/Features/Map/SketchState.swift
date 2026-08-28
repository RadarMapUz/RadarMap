//
//  SketchState.swift
//  RadarMap
//
//  Экранная модель схемы приборки: держит сцену «север вверху» и точку
//  зрения, решает, когда пересобирать растр, и анимирует движение между
//  GPS-тиками. Сами решения — чистые функции RoadSketch (тестируются),
//  здесь только их привязка к сервисам и к анимации.
//
//  Анимация нарочно императивная (withAnimation при записи значений), а не
//  декларативная (.animation во вью): при пересборке растра опора «переезжает»
//  в текущую точку, и смещение с растром обязаны смениться В ОДНОМ кадре БЕЗ
//  анимации — они взаимно компенсируются, и картинка не дёргается. Анимировать
//  этот переход значило бы секунду везти новый растр на место старого.
//

import CoreLocation
import MapKit
import Observation
import SwiftUI

@MainActor
@Observable
final class SketchState {
    /// Растр: пересобирается на смене данных или уходе от опоры (needsRebuild).
    private(set) var scene: RoadSketch.Scene?
    /// Я относительно опоры сцены, метры (восток, север). Анимируется каждый
    /// тик — движение между тиками изображает transform, а не перерисовка.
    private(set) var meOffset = CGSize.zero
    /// Размотанный курс (может выходить за 0…360 — так поворот 359°→1°
    /// анимируется на +2°, а не на −358°).
    private(set) var courseDegrees = 0.0
    /// Точный охват вида; растр докручивается scaleEffect'ом до него.
    private(set) var spanMeters = RoadSketch.minSpanMeters
    /// Курс был хоть раз. Ложь — схема рисуется СЕВЕРОМ ВВЕРХ и курсор
    /// показывается точкой, а не стрелкой: где мы — знаем, куда смотрим — нет.
    private(set) var hasCourse = false

    // MARK: - Осмотр: панорама и зум
    //
    // Схема — прибор с прибитой точкой зрения, и это правильно за рулём. Но
    // посмотреть, что там впереди за поворотом, иногда надо, и тогда вид
    // отвязывается от машины. Отвязка обязана быть ВРЕМЕННОЙ: экран, молча
    // оставшийся не там, где машина, — самое опасное, что можно сделать.
    //
    // Устройство простое: центр вида и машина разведены. Обычно они совпадают,
    // при осмотре центр замирает, а машина продолжает ехать — и курсор уезжает
    // от середины экрана ровно на разницу.

    /// Центр вида относительно опоры сцены, метры. Обычно равен meOffset.
    private(set) var viewOffset = CGSize.zero
    /// Машина относительно центра вида, метры. Обычно ноль.
    private(set) var cursorOffset = CGSize.zero
    /// Вид отвязан от машины.
    private(set) var isInspecting = false

    /// Почему схема сейчас вблизи. nil — обычный обзор.
    ///
    /// Хранится, а не считается заново: на нём держится гистерезис, без
    /// которого один и тот же перекрёсток включал бы и выключал вид каждую
    /// секунду.
    private(set) var closeReason: RoadSketch.CloseReason?
    /// С какого момента ползём. nil — едем.
    @ObservationIgnored private var crawlSince: Date?
    /// Ключ сцены, под которую сажались подписи.
    @ObservationIgnored private var labelsKey: RoadSketch.RebuildKey?

    /// Высота вью в пунктах: по ней экранный сдвиг переводится в метры.
    /// Ставит сама вью — состояние про экран ничего не знает.
    ///
    /// На изменении поля пересчитываются: панели свою высоту меряют один раз
    /// при раскладке, а схема появляется позже (её монтируют, только когда
    /// она на экране). Без пересчёта первый показ шёл бы с пустыми полями —
    /// то есть ровно с той проекцией, которую мы и чиним.
    @ObservationIgnored var viewHeight: CGFloat = 0 {
        didSet {
            guard viewHeight != oldValue else { return }
            applyPanelEdges()
        }
    }
    /// Последние кромки панелей в пунктах окна: хранятся, потому что высота
    /// вью и замер панелей приходят в разном порядке.
    @ObservationIgnored private var panelTop: CGFloat = 0
    @ObservationIgnored private var panelBottom: CGFloat = 0
    /// Ширина вью в пунктах: нужна подписям, чтобы резать улицы по видимому
    /// прямоугольнику, а не по одной высоте.
    @ObservationIgnored var viewWidth: CGFloat = 0

    /// Поля вида: какую долю высоты закрывают панели хоста.
    ///
    /// Ставит ХОЗЯИН экрана, а не вью схемы: панели знает он. На приборке и в
    /// CarPlay схема ничем не закрыта, и поля остаются пустыми.
    private(set) var insets = RoadSketch.Insets.none

    /// Подписи улиц на текущий кадр.
    ///
    /// Не в сцене, а здесь, и это главная правка подписей: сцена живёт сотни
    /// метров и не знает, что именно видно СЕЙЧАС. Подпись, посаженная в
    /// середину улицы по всему растру, уезжала за экран вместе с этой
    /// серединой — на четырёх снимках живой поездки не было ни одной подписи
    /// при пяти-восьми подписываемых улицах в кадре.
    private(set) var labels: [RoadSketch.Label] = []

    /// Хост измерил свои панели: нижняя кромка верхней стопки и верхняя
    /// кромка нижней, в пунктах окна. Схема сама переводит их в доли своей
    /// высоты — про экран знает она, про панели знает хост.
    func setPanelEdges(top: CGFloat, bottom: CGFloat) {
        panelTop = top
        panelBottom = bottom
        applyPanelEdges()
    }

    private func applyPanelEdges() {
        guard viewHeight > 0 else { return }
        let top = panelTop, bottom = panelBottom
        let height = Double(viewHeight)
        // Ноль снизу — «ещё не мерили», а не «панель во весь экран»: до
        // первого замера поле обязано быть пустым, иначе первый же кадр
        // схемы сожмётся в треть экрана.
        let bottomInset = bottom > 0 ? max(0, height - Double(bottom)) / height : 0
        setInsets(top: max(0, Double(top)) / height, bottom: bottomInset)
    }

    /// Хост измерил свои панели. Пишем только на изменение: поля приходят из
    /// раскладки, а раскладка случается чаще, чем меняются высоты.
    func setInsets(top: Double, bottom: Double) {
        let fresh = RoadSketch.Insets(top: top, bottom: bottom)
        guard fresh != insets else { return }
        insets = fresh
        // Проекция изменилась: растр собран под прежние поля, и «я» в нём
        // стоит не там, где теперь смотрят.
        key = nil
    }
    /// Охват на момент начала осмотра: во время него он держится сам, а не
    /// выбирается по скорости и расстоянию до камеры.
    @ObservationIgnored private var inspectSpan: Double?
    @ObservationIgnored private var returnTask: Task<Void, Never>?

    #if DEBUG
    /// Границы зума проверяются тестом, а поле остаётся приватным: наружу оно
    /// не нужно никому, кроме проверки.
    var inspectSpanForTests: Double? { inspectSpan }
    #endif

    /// Палец лёг на схему: автовозврат откладывается до отпускания.
    func beginInspect() {
        returnTask?.cancel()
        returnTask = nil
        if !isInspecting {
            isInspecting = true
            inspectSpan = spanMeters
        }
    }

    /// Тянем вид. Сдвиг приходит экранный, хранится в метрах сцены.
    func pan(by translation: CGSize) {
        guard isInspecting else { return }
        let delta = RoadSketch.sceneOffset(fromScreen: translation,
                                           courseDegrees: courseDegrees,
                                           spanMeters: spanMeters,
                                           viewHeight: viewHeight)
        viewOffset = CGSize(width: viewOffset.width + delta.width,
                            height: viewOffset.height + delta.height)
        cursorOffset = CGSize(width: meOffset.width - viewOffset.width,
                              height: meOffset.height - viewOffset.height)
    }

    /// Щипок. Границы те же, что у автоматики: ближе минимума схему трясёт от
    /// шума GPS, дальше максимума она перестаёт отвечать на свой вопрос.
    func zoom(by factor: Double) {
        guard isInspecting, let base = inspectSpan else { return }
        let wanted = base / max(0.2, factor)
        inspectSpan = min(RoadSketch.maxSpanMeters,
                          max(RoadSketch.minSpanMeters, wanted))
    }

    /// Палец отпущен: заводим автовозврат.
    func endInspect() {
        guard isInspecting else { return }
        returnTask?.cancel()
        returnTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(RoadSketch.inspectReturnSeconds))
            guard !Task.isCancelled else { return }
            self?.returnToMe()
        }
    }

    /// Вернуться к машине. Зовётся кнопкой, автовозвратом и тревогой.
    func returnToMe() {
        returnTask?.cancel()
        returnTask = nil
        guard isInspecting else { return }
        isInspecting = false
        inspectSpan = nil
        withAnimation(.easeOut(duration: 0.45)) {
            viewOffset = meOffset
            cursorOffset = .zero
        }
    }

    // MARK: - Мировые слои поверх растра
    //
    // Всё, что меняется чаще растра, но живёт в мировых метрах, лежит здесь и
    // едет под теми же тремя transform'ами, что и растр, — то есть движется
    // вместе с дорогами само, без единого пересчёта на кадр. Класть это в
    // растр было бы нельзя: маршрут «пройден до сих пор» меняется непрерывно
    // и заставил бы пересобирать растр каждые несколько метров.

    /// Стрелка манёвра: кусок маршрута вокруг точки поворота, метры от опоры.
    /// Пусто — манёвра нет, он далеко или уже пройден.
    private(set) var maneuverPath: [CGPoint] = []
    /// Тип ближайшего манёвра — им выбирается голова стрелки и подсветка
    /// «нашей» полосы. nil — движок типа не сообщил.
    private(set) var maneuverKind: ManeuverKind?
    /// Полосы на подходе к манёвру. Пусто — данных нет, и пузыря нет.
    private(set) var lanes: [LaneHint] = []
    /// Пройденный кусок маршрута позади, метры от опоры.
    private(set) var passedPath: [CGPoint] = []
    /// Имя улицы под нами. nil — безымянна или мы не на ней.
    private(set) var currentStreet: String?

    /// Прогресс, на котором в последний раз пересчитан пройденный кусок.
    /// Пересчитывать его на каждом фиксе незачем: на экране это доли пункта.
    @ObservationIgnored private var passedAt: CLLocationDistance = -1
    @ObservationIgnored private var maneuverAt: CLLocationDistance = -1
    /// Опора, в координатах которой посчитаны мировые слои. Переезд опоры
    /// обязан пересчитать их немедленно: иначе стрелка манёвра осталась бы
    /// висеть в координатах прошлой сцены, то есть уехала бы в сторону ровно
    /// на длину переезда.
    /// Гейт пересчёта имени улицы: раз в полсотни метров пути.
    @ObservationIgnored private var street = StreetNameGate()

    private struct StreetNameGate {
        private var at: CLLocationCoordinate2D?
        func shouldRefresh(at coordinate: CLLocationCoordinate2D) -> Bool {
            guard let at else { return true }
            return GeoMath.fastDistance(at.latitude, at.longitude,
                                        coordinate.latitude, coordinate.longitude) > 50
        }
        mutating func mark(_ coordinate: CLLocationCoordinate2D) { at = coordinate }
    }

    @ObservationIgnored private var layersAnchorLatitude = Double.nan
    @ObservationIgnored private var layersAnchorLongitude = Double.nan

    @ObservationIgnored private var unwoundCourse: Double?
    @ObservationIgnored private var key: RoadSketch.RebuildKey?
    /// Когда пришёл прошлый тик: анимация точки зрения длится ровно до
    /// следующего ожидаемого фикса, а не фиксированную секунду.
    @ObservationIgnored private var lastTickAt: Date?
    /// Мелкие улицы видны (мы сами на такой). Два тика подряд на смену:
    /// на границе двора с проспектом решение не должно мигать.
    @ObservationIgnored private var minorsVisible = false
    @ObservationIgnored private var minorFlipTicks = 0

    /// Тик GPS: дёргается из DashboardView по locationTick. `now` — параметр
    /// (не Date() внутри): ритм анимации детерминирован в тестах.
    func refresh(_ env: AppEnvironment, now: Date = Date()) {
        // Схема на приборке — единственное, что считается на каждом тике ради
        // картинки. Она обязана быть самым дешёвым экраном, а не самым дорогим,
        // и проверять это надо приборами, а не на глаз.
        let token = Perf.begin(Perf.Name.sketchRefresh)
        defer { token.end() }
        // Координата и курс ДЛЯ КАРТИНКИ: прижаты к оси дороги, когда мы на
        // ней (RoadSnapper). Стрелка идёт по полотну, а не по газону рядом,
        // и схему не покачивает от бокового шума GPS.
        guard let me = env.location.displayCoordinate
            ?? env.location.currentCoordinate else { return }
        // Время суток — та же ручка, что у подложки карты. Спрашиваем на тике,
        // а не подписываемся: ответ солнца меняется дважды в сутки, и лишняя
        // подписка стоила бы больше, чем сравнение двух Bool.
        let daylight = env.settings.mapAppearance.isDaylight(at: me, now: now)
        if SketchPalette.daylight != daylight {
            SketchPalette.daylight = daylight
            // Сцена нарисована прежними тонами и обязана пересобраться:
            // ключ пересборки о палитре не знает, и без сброса схема
            // осталась бы ночной до ближайшего движения на сотню метров.
            key = nil
        }
        unwoundCourse = RoadSketch.unwound(unwoundCourse,
                                           towards: env.location.displayCourse >= 0
                                               ? env.location.displayCourse
                                               : env.location.currentCourse)
        // Курса не было ни разу — холодный старт на стоянке или светофор до
        // первого движения. Поворачивать схему наугад по-прежнему нельзя:
        // это враньё про направление. Но и прятать её незачем — где мы,
        // известно точно. Показываем СЕВЕРОМ ВВЕРХ, а курсор рисуется точкой:
        // «вот здесь ты, куда смотришь — не знаю» честнее пустого экрана.
        let course = unwoundCourse ?? 0
        hasCourse = unwoundCourse != nil

        let alert = env.location.nearestCamera
        let distance = env.location.distanceToNearest
        // Скорость задаёт нижнюю границу охвата: вид отъезжает ровно настолько,
        // чтобы в кадре оставался тот же отрезок ВРЕМЕНИ. Ступени масштаба
        // (bucket) гасят дрожание от каждого километра в час.
        // При осмотре охват держит пользователь: автоматика, продолжая
        // выбирать масштаб, дралась бы с щипком.
        // Вид вблизи: подход к манёвру, тревожная камера рядом, двор или
        // пробка. Включает СОБЫТИЕ, а не скорость, и держится с запасом —
        // вид, дёргающийся между масштабами на каждом перекрёстке, хуже
        // любого из них.
        let speed = env.location.speedKmh
        if speed <= RoadSketch.closeSlowKmh {
            if crawlSince == nil { crawlSince = Date() }
        } else if speed > RoadSketch.closeSlowKmh * RoadSketch.closeSlowExitFactor {
            crawlSince = nil
        }
        let crawling = crawlSince.map { Date().timeIntervalSince($0) } ?? 0
        let toManeuver = env.route.isActive && env.route.nextStep != nil
            ? env.route.nextStepDistance : nil
        let toCamera = alert != nil ? distance : nil
        closeReason = RoadSketch.closeReason(
            toManeuver: toManeuver,
            toCamera: toCamera,
            speedKmh: speed, crawlingSeconds: crawling,
            // Двор берём с прошлого тика: решение о мелких улицах считается
            // ниже, по уже выбранному охвату, и одного тика задержки здесь не
            // видно — у самого решения гистерезис в два тика.
            onMinorRoad: minorsVisible,
            wasClose: closeReason != nil)

        let span = inspectSpan
            ?? (closeReason.map { reason in
                isInspecting
                    ? RoadSketch.span(forDistance: toCamera, speedKmh: speed,
                                      insets: insets)
                    : RoadSketch.closeSpan(reason: reason, toManeuver: toManeuver,
                                           toCamera: toCamera, insets: insets)
            } ?? RoadSketch.span(forDistance: toCamera, speedKmh: speed,
                                 insets: insets))
        let inRange: Bool = if let distance, alert != nil {
            RoadSketch.isInRange(distance: distance, span: span, insets: insets)
        } else {
            false
        }

        // Тревожная камера отменяет осмотр немедленно: камера впереди — не тот
        // момент, когда на экране чужой район. Это единственный случай, когда
        // рука пользователя перебивается.
        if inRange, isInspecting { returnToMe() }

        // Мелкие улицы: видны, только когда мы сами на такой. Решение с
        // гистерезисом в два тика — иначе на границе двора с проспектом
        // растр пересобирался бы туда-сюда.
        let source = network(env, span: span)
        let wantsMinors = RoadSketch.prefersMinorRoads(network: source, at: me)
        // Имя улицы считается на пересборке растра, а не на тике: улица под
        // нами меняется на сотнях метров, а тик приходит раз в секунду.
        // Кэш окрестности внутри источника делает сам запрос почти бесплатным,
        // но перебор имён по нему — уже нет.
        if street.shouldRefresh(at: me) {
            currentStreet = RoadSketch.currentStreet(network: source, at: me)
            street.mark(me)
        }
        if wantsMinors != minorsVisible {
            minorFlipTicks += 1
            if minorFlipTicks >= 2 {
                minorsVisible = wantsMinors
                minorFlipTicks = 0
            }
        } else {
            minorFlipTicks = 0
        }

        // Тайлы окрестности: дёшево, когда всё на месте; скачивает недостающее
        // только пока приборка на экране.
        //
        // Наборы заказываем по тому, что схема СЕЙЧАС показывает, — поэтому
        // после охвата и решения про мелкие улицы, а не до них. Слой,
        // невидимый на текущем охвате, не качается и не разбирается вовсе:
        // дворовые проезды это половина всех дорог, и в общем файле они ехали
        // бы на телефон всю поездку ради случая, который наступает под конец.
        // Набор точек заказываем по ТОЙ ЖЕ развилке, по которой выбирается
        // сеть, а не по одному охвату: пока костяк не приехал, схема рисует
        // детальную сеть, и точки нужны её собственные. Иначе в окне между
        // «охват вырос» и «костяк загрузился» на детальные улицы лёг бы набор,
        // посчитанный по другой геометрии.
        let onFarNetwork = usesFarNetwork(env, span: span)
        env.roads.setWantedSets(wantedSets(span: span, minors: minorsVisible,
                                           far: onFarNetwork))
        // Тайлы просим вокруг ЦЕНТРА ВИДА, а не вокруг машины: при осмотре
        // взгляд уходит туда, где тайлов ещё нет, и без этого панорама
        // упиралась бы в чёрное.
        env.roads.ensureCoverage(around: viewCentre(from: me))

        let freshKey = RoadSketch.RebuildKey(
            alertCameraID: inRange ? alert?.id : nil,
            alertInRange: inRange,
            spanBucket: RoadSketch.bucket(forSpan: span),
            routeToken: env.route.polyline.map(ObjectIdentifier.init),
            networkGeneration: env.speedLimits.indexRevision,
            roadsGeneration: env.roads.revision,
            storeRevision: env.cameras.revision,
            budget: env.thermal.mode.sketchNetworkBudget,
            minorRoads: minorsVisible,
            areasGeneration: env.roads.areas.count,
            marksGeneration: env.roads.points.count &+ env.roads.farPoints.count,
            farNetwork: usesFarNetwork(env, span: span))
        let offset = offsetMeters(of: me)

        // Плавность — это ритм: анимация длится до следующего ОЖИДАЕМОГО
        // фикса (лучшее предсказание интервала — предыдущий), а не жёсткую
        // секунду. С константой схема секунду ехала и две стояла — фиксы на
        // крейсере приходят раз в 15–25 метров.
        let duration = TickPacing.animationDuration(
            sincePreviousTick: lastTickAt.map { now.timeIntervalSince($0) })
        lastTickAt = now

        // Пересобирать растр надо, когда от опоры уехал ЦЕНТР ВИДА, а не
        // машина: при осмотре они расходятся, и следить надо за тем, что
        // человек видит.
        let viewDrift = isInspecting
            ? CGPoint(x: viewOffset.width, y: viewOffset.height)
            : offset
        if RoadSketch.needsRebuild(scene: scene, key: freshKey, previousKey: key,
                                   meOffsetMeters: viewDrift) {
            // Переезд опоры: растр и смещение меняются в одном кадре без
            // анимации и взаимно компенсируются — картинка стоит на месте.
            let centre = viewCentre(from: me)
            scene = build(env: env, me: centre, span: span,
                          alert: alert, inRange: inRange)
            // Новая опора — центр вида. Машина отсчитывается от него же.
            meOffset = CGSize(width: offsetMeters(of: me).x,
                              height: offsetMeters(of: me).y)
            viewOffset = .zero
            cursorOffset = isInspecting ? meOffset : .zero
            withAnimation(.linear(duration: duration)) {
                courseDegrees = course
                spanMeters = span
            }
        } else if isInspecting {
            // Вид замер, машина едет: двигается только курсор.
            meOffset = CGSize(width: offset.x, height: offset.y)
            withAnimation(.linear(duration: duration)) {
                cursorOffset = CGSize(width: offset.x - viewOffset.width,
                                      height: offset.y - viewOffset.height)
                courseDegrees = course
                spanMeters = span
            }
        } else {
            // Гейт неподвижности: на светофоре тики идут, а картинка стоит —
            // не пишем ничего, и композитор не получает ни кадра работы.
            let offsetDelta = hypot(offset.x - meOffset.width,
                                    offset.y - meOffset.height)
            if RoadSketch.viewpointMoved(offsetDeltaMeters: offsetDelta,
                                         courseDeltaDegrees: abs(course - courseDegrees),
                                         spanChanged: span != spanMeters) {
                withAnimation(.linear(duration: duration)) {
                    meOffset = CGSize(width: offset.x, height: offset.y)
                    viewOffset = CGSize(width: offset.x, height: offset.y)
                    courseDegrees = course
                    spanMeters = span
                }
            }
        }
        key = freshKey
        refreshRouteLayers(env)
        refreshLabels(span: span)
    }

    /// Подписи улиц под текущую точку зрения.
    ///
    /// Каждый тик, а не на пересборке растра: подпись обязана сидеть в том
    /// куске улицы, который виден СЕЙЧАС. Дюжина строк на дюжину улиц — цена
    /// одного перебора сети, уже урезанной бюджетом.
    ///
    /// Только на ближнем плане: на дальнем схема рисует костяк района, где
    /// раздельные проезжие сведены в одну ось, и подпись висела бы между
    /// двумя проезжими частями. Тот же порог, что у обстановки.
    private func refreshLabels(span: Double) {
        guard let scene, span <= RoadSketch.farNetworkSpan,
              viewHeight > 0, viewWidth > 0 else {
            if !labels.isEmpty { labels = [] }
            return
        }
        let aspect = Double(viewWidth / viewHeight)
        let anchor = CGPoint(x: meOffset.width, y: meOffset.height)
        // Пока все подписи на экране и сеть та же — не трогаем: подпись,
        // пересаживаемая на каждом фиксе, ползала бы по улице.
        if !labels.isEmpty, labelsKey == key,
           labels.allSatisfy({ RoadSketch.isSeated($0.point, meOffset: anchor,
                                                   courseDegrees: courseDegrees,
                                                   spanMeters: spanMeters,
                                                   aspect: aspect, insets: insets) }) {
            return
        }
        labelsKey = key
        let fresh = RoadSketch.labels(
            for: scene.network,
            meOffset: anchor,
            courseDegrees: courseDegrees, spanMeters: spanMeters,
            aspect: aspect, insets: insets, viewHeight: Double(viewHeight))
        if fresh != labels { labels = fresh }
    }

    /// Мировые слои маршрута: стрелка манёвра и пройденный кусок.
    ///
    /// Оба считаются ОТ ОПОРЫ ТЕКУЩЕЙ СЦЕНЫ, поэтому пересчитываются и при
    /// её переезде — иначе после пересборки растра стрелка осталась бы
    /// висеть в координатах прошлой опоры, то есть уехала бы в сторону.
    private func refreshRouteLayers(_ env: AppEnvironment) {
        guard let scene, env.route.isActive else {
            maneuverPath = []
            maneuverKind = nil
            lanes = []
            passedPath = []
            passedAt = -1
            maneuverAt = -1
            layersAnchorLatitude = .nan
            layersAnchorLongitude = .nan
            return
        }
        let anchor = scene.anchor
        let coordinates = env.route.routeCoordinates
        let progress = env.route.progressAlong
        let anchorMoved = anchor.latitude != layersAnchorLatitude
            || anchor.longitude != layersAnchorLongitude
        layersAnchorLatitude = anchor.latitude
        layersAnchorLongitude = anchor.longitude

        // Стрелка манёвра — на смене шага, на сдвиге опоры и по мере
        // приближения (окно едет вместе с нами, пока манёвр не пройден).
        let step = env.route.nextStep
        let window = step.flatMap {
            RoadSketch.maneuverWindow(stepAlong: $0.distanceAlong, progress: progress)
        }
        if let step, let window {
            let moved = abs(progress - maneuverAt) >= AppConfig.carPlayTraveledStepMeters
            if anchorMoved || moved || maneuverPath.isEmpty || maneuverKind != step.kind {
                maneuverAt = progress
                maneuverPath = RoadSketch.subPath(coordinates, from: window.from,
                                                  to: window.to, anchor: anchor)
            }
            maneuverKind = step.kind
            lanes = step.lanes
        } else {
            maneuverPath = []
            maneuverKind = nil
            lanes = []
            maneuverAt = -1
        }

        // Пройденное — шагом, а не каждым фиксом: снимать и класть слой
        // ежесекундно значит платить за то, чего на экране не видно.
        if progress <= 1 {
            passedPath = []
            passedAt = -1
        } else if anchorMoved
            || abs(progress - passedAt) >= AppConfig.carPlayTraveledStepMeters {
            passedAt = progress
            passedPath = RoadSketch.subPath(
                coordinates,
                from: max(0, progress - RoadSketch.passedVisibleMeters),
                to: progress, anchor: anchor)
        }
    }

    /// Наборы тайлов, нужные на этом охвате.
    ///
    /// Костяк и улицы — всегда: без них схемы нет. Дворы — когда мы сами на
    /// мелкой улице. Местность — вода, зелень, рельсы — тоже всегда: это
    /// крупные ориентиры, они дёшевы и читаются на любом охвате. Кварталы —
    /// только вблизи, где они и различимы.
    private func wantedSets(span: Double, minors: Bool,
                            far: Bool) -> Set<RoadTiles.Set> {
        var sets: Set<RoadTiles.Set> = [.far, .streets, .water, .green, .rail]
        if minors { sets.insert(.yards) }
        if span < SketchArea.Kind.block.maxSpanMeters { sets.insert(.blocks) }
        // Тротуаров больше, чем всех улиц вместе (3 439 против 8 455 дорог в
        // одном центре Ташкента), а видны они только вблизи. Слой, невидимый
        // на текущем охвате, не качается и не разбирается — тот же закон, что
        // у дворовых проездов и кварталов.
        if span < SketchArea.Kind.sidewalk.maxSpanMeters { sets.insert(.sidewalks) }
        // Дома — тот же закон и самый сильный повод: их 54 094 в одном кадре
        // центра против семисот дорог, то есть слой домов один весит больше,
        // чем вся остальная схема. Качаем их только там, где водитель уже
        // ищет подъезд.
        if span < SketchArea.Kind.house.maxSpanMeters { sets.insert(.houses) }
        // Поверхность дороги — ближний охват и только он.
        //
        // Штрихами реалистичную дорогу не нарисовать никакой толщиной: у
        // штриха нет ни кромки, ни площади перекрёстка, ни расширения перед
        // ним. Всё это посчитано сборкой раз в неделю и лежит готовым; на
        // дальнем плане полотно вырождается в линию, и там штрих честнее.
        if span < SketchArea.Kind.road.maxSpanMeters { sets.insert(.surface) }
        // Точки — из того набора, что посчитан по РИСУЕМОЙ сети. Просить оба
        // разом значило бы возить вдвое больше ради слоя, из которого виден
        // ровно один.
        if far {
            sets.insert(.pointsFar)
        } else if SketchPoint.Kind.allCases.contains(where: { $0.maxSpanMeters >= span }) {
            sets.insert(.points)
        }
        return sets
    }

    /// Точки под текущую сеть. Та же развилка, что у самой сети: рисуем
    /// костяк — берём точки костяка.
    private func sketchPoints(_ env: AppEnvironment, span: Double) -> [SketchPoint] {
        usesFarNetwork(env, span: span) ? env.roads.farPoints : env.roads.points
    }

    /// Один источник сети на тик и на сборку: свои тайлы, где есть, иначе
    /// индекс лимитов.
    ///
    /// На дальнем охвате берётся КОСТЯК района — отдельный набор, где
    /// раздельные проезжие уже сведены в одну ось, а мелочи нет вовсе.
    /// Подмножеством обычной сети он быть не может: схлопывание даёт другую
    /// геометрию, а не выборку из той же.
    private func network(_ env: AppEnvironment, span: Double) -> FallbackRoadNetwork {
        let far = env.roads.farNetwork
        return FallbackRoadNetwork(primary: usesFarNetwork(env, span: span)
                                       ? far : env.roads.network,
                                   fallback: env.speedLimits.sketchNetwork)
    }

    private func usesFarNetwork(_ env: AppEnvironment, span: Double) -> Bool {
        span >= RoadSketch.farNetworkSpan && !(env.roads.farNetwork is EmptyRoadNetwork)
    }

    /// Координата центра вида: опора плюс смещение вида.
    private func viewCentre(from me: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard isInspecting, let scene else { return me }
        let anchor = scene.anchor
        let metersPerLon = 111_320.0 * cos(anchor.latitude * .pi / 180)
        return CLLocationCoordinate2D(
            latitude: anchor.latitude + Double(viewOffset.height) / 111_320.0,
            longitude: anchor.longitude + Double(viewOffset.width) / metersPerLon)
    }

    private func offsetMeters(of me: CLLocationCoordinate2D) -> CGPoint {
        guard let scene else { return .zero }
        let anchor = scene.anchor
        return CGPoint(
            x: (me.longitude - anchor.longitude)
                * 111_320.0 * cos(anchor.latitude * .pi / 180),
            y: (me.latitude - anchor.latitude) * 111_320.0)
    }

    private func build(env: AppEnvironment, me: CLLocationCoordinate2D,
                       span: Double, alert: Camera?, inRange: Bool) -> RoadSketch.Scene {
        let radius = RoadSketch.sceneRadius(forSpan: span)
        // Камеры охвата — как на карте: с учётом фильтра вида. Тревожную
        // scene() гарантирует сама, даже если фильтр её спрятал.
        let region = MKCoordinateRegion(center: me, latitudinalMeters: radius * 2,
                                        longitudinalMeters: radius * 2)
        let dots = env.cameras.cameras(in: region, limit: 80)
            .filter { env.settings.filter.matches($0) }
        return RoadSketch.scene(alertCamera: alert, alertInRange: inRange,
                                cameras: dots,
                                // Свои тайлы (классы, мосты, дворы), где они
                                // уже есть; иначе — сеть из индекса лимитов.
                                network: network(env, span: span),
                                networkBudget: env.thermal.mode.sketchNetworkBudget,
                                showMinorRoads: minorsVisible,
                                precomputed: env.roads.isPrecomputed,
                                areas: env.roads.areas,
                                areaBudget: env.thermal.mode.sketchAreaBudget,
                                points: sketchPoints(env, span: span),
                                route: env.route.routeCoordinates,
                                track: env.trip.recentTrack(),
                                anchor: me, spanMeters: span)
    }
}
