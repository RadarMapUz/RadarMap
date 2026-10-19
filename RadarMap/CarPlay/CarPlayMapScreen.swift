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
    /// Карта на движке: панорама от шаблона (счётчик и сдвиг содержимого в
    /// точках), «+/−» при слежении — сдвиг автозума вдвое за нажатие (как на
    /// телефоне), «+/−» на свободной карте — шаг уровня.
    /// Сумма всех сдвигов панорамы (точки экрана) — карта берёт разницу.
    var panTotal = CGSize.zero
    var zoomBias = 0.0
    /// Сглаживание камеры поездки (DriveCamera): кадр подходит к цели плавно.
    /// Шаг делает вид карты на каждом своём пересчёте — состояние не
    /// наблюдаемое, перерисовку оно не вызывает.
    @ObservationIgnored var cameraSmoother = DriveCamera.Smoother()
    /// На ходу — только дорога (DrivingDeclutter); пишет тело карты на тике.
    @ObservationIgnored var declutter = DrivingDeclutter()
    /// Поворот карты, каким его нарисовал движок (после каждого хода
    /// камеры). Камеру «держать в кадре» считаем по нему, а не по курсу:
    /// поворот, которого карта не сделала, кадр не спасает.
    @ObservationIgnored var mapDirection: Double?
    var zoomCommand = 0
    /// На экране выбор маршрута (CarPlayTripPreview): навигационная сессия
    /// ждёт «Поехали», бар — одна «Отмена».
    var isPreviewing = false
    /// «Весь маршрут» — вписать линию в экран (выбор маршрута).
    var overviewCommand = 0

    /// Обзор маршрута — это уже не слежение: «+/−» в нём приближают саму
    /// карту. До 18.10 модель считала, что следит, и «+/−» на экране выбора
    /// маршрута меняли только автозум, которого не видно.
    func showOverview() {
        overviewCommand &+= 1
        send(.overview)
    }
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
    /// а рисует и греется телефон. Ставит делегат сцены — по настоящему
    /// состоянию сцены, а не «пока не сказали иначе»: до 2.2.6 здесь стояло
    /// true, и сцена, подключённая в фоне (на экране машины Яндекс), сразу
    /// поднимала карту и HUD в окне, которое никто не показывал.
    var isOnScreen = false
    /// Последний тик GPS, на который экран машины действительно перерисовался.
    /// Пишет вью (onChange тика), читает сторож застывания в делегате: тики
    /// идут, а это число стоит — дерево интерфейса в окне машины мертво.
    @ObservationIgnored var lastRenderedTick = 0
    /// Последний удар пульса экрана (TimelineView в CarPlayLiveness). В отличие
    /// от тика GPS бьёт и у стоящей машины, поэтому сторож видит застывание
    /// и тогда, когда фиксов нет минутами.
    @ObservationIgnored var lastHeartbeat = Date()
    /// Едет ли карта за машиной — зеркало `browse.following` для значка
    /// кнопки «к себе»: залитый — следим, контурный — стоим.
    private(set) var isFollowing = true
    /// Осмотр карты: следим ли, открыт ли интерфейс осмотра (CarPlayBrowse).
    @ObservationIgnored private var browse = CarPlayBrowse.State()
    /// Закрыть интерфейс осмотра шаблона — ставит делегат сцены. Без этого
    /// возврат к машине оставлял в баре одну «Готово» (аудит 18.10, п. 1).
    @ObservationIgnored var onClosePanning: (() -> Void)?
    /// Сколько занимают кнопки карты по краям окна (mapButtonSafeAreaLayoutGuide):
    /// HUD у правого края встаёт левее них. Меняется со сменой экрана.
    var mapButtonInsets = EdgeInsets()
    /// Сдвиг карты на столько точек экрана (содержимое едет за пальцем).
    func pan(by translation: CGSize) {
        guard translation != .zero else { return }
        panTotal = CGSize(width: panTotal.width + translation.width,
                          height: panTotal.height + translation.height)
        send(.moved)
    }

    /// «+ / −». При слежении меняется автозум (масштаб по скорости остаётся,
    /// сдвигается его уровень), на свободной карте — сам вид.
    func zoom(in zoomIn: Bool) {
        if browse.following {
            zoomBias = min(AppConfig.carPlayZoomBiasLimit,
                           max(-AppConfig.carPlayZoomBiasLimit, zoomBias + (zoomIn ? 1 : -1)))
        } else {
            zoomDelta = zoomIn ? 1 : -1
            zoomCommand &+= 1
        }
        send(.zoomed)
    }

    /// «К себе»: карта снова едет за машиной.
    func recenter() { send(.recenter) }

    /// Интерфейс осмотра шаблона открылся / закрылся (делегат сцены).
    func panningShown() { send(.panningShown) }
    func panningHidden() { send(.panningHidden) }

    /// Карта ушла в осмотр сама (движок получил панораму): модель обязана
    /// знать, иначе «+/−» шли бы в автозум карты, которая стоит.
    func mapStartedBrowsing() {
        if browse.following { send(.moved) }
    }

    /// Новая карта (вернулись из музыки) стартует со слежения — модель
    /// обязана сказать то же, иначе после давней панорамы «+/−» шли бы в
    /// «свободную карту», которой нет, а «к себе» показывал «не следим».
    func adoptFollowing() {
        guard !browse.following else { return }
        browse.following = true
        returnTask?.cancel()
        returnTask = nil
        isFollowing = true
        // Интерфейс осмотра при этом может стоять (вернулись из музыки, окно
        // пересоздал сторож): без таймера он остался бы с одной «Готово».
        if browse.panning { armIdle() }
    }

    #if DEBUG
    /// Только для тестов: слежение без таймеров и команд карте (CarPlayEngineTests
    /// держат одну модель на класс — таймер прошлого теста не должен сработать
    /// посреди следующего).
    func setFollowingForTesting(_ following: Bool) {
        returnTask?.cancel()
        returnTask = nil
        browse = CarPlayBrowse.State(following: following, panning: false)
        isFollowing = following
    }
    #endif

    /// Одно решение на событие (CarPlayBrowse), здесь — только исполнение.
    private func send(_ event: CarPlayBrowse.Event) {
        for effect in CarPlayBrowse.reduce(&browse, event, previewing: isPreviewing) {
            switch effect {
            case .armIdle:
                armIdle()
            case .cancelIdle:
                returnTask?.cancel()
                returnTask = nil
            case .recenter:
                recenterRequests &+= 1
            case .closePanning:
                onClosePanning?()
            }
        }
        if isFollowing != browse.following { isFollowing = browse.following }
    }

    /// Щипок: масштаб текущего вида на свободной карте, сдвиг автозума при
    /// слежении. Накопленный масштаб жеста превращается в шаги уровня, когда
    /// набирает удвоение — иначе каждый кадр жеста дёргал бы камеру.
    func pinch(scale: Double) {
        guard scale > 0 else { return }
        pinchAccumulated *= scale
        while pinchAccumulated >= 2 { pinchAccumulated /= 2; zoom(in: true) }
        while pinchAccumulated <= 0.5 { pinchAccumulated *= 2; zoom(in: false) }
    }
    @ObservationIgnored private var pinchAccumulated = 1.0

    /// Новый жест щипка — остаток прошлого не переносится.
    func pinchBegan() { pinchAccumulated = 1 }

    /// Автовозврат: водитель отпанорамировал или открыл осмотр и забыл —
    /// карта не должна стоять, а бар — оставаться «осмотровым», пока он едет.
    /// Таймер взводится каждым движением и гасится «к себе»; камера впереди
    /// возвращает всё сразу (returnOnAlert).
    @ObservationIgnored private var returnTask: Task<Void, Never>?

    private func armIdle() {
        returnTask?.cancel()
        returnTask = Task { @MainActor [weak self] in
            await Task.pause(seconds: AppConfig.carPlayFollowReturnSeconds)
            guard !Task.isCancelled, let self else { return }
            Log.carplay.notice("карта: возврат к машине по бездействию")
            self.send(.idleTimeout)
        }
    }

    /// Камера впереди — карта обязана ехать за машиной, где бы её ни оставили,
    /// и осмотр закрывается вместе с ней.
    func returnOnAlert() { send(.cameraAhead) }

    /// Пересчитать день/ночь. Ручной выбор старше всего; в «Авто» — машина,
    /// а без её ответа — солнце (`sunDay` = AppEnvironment.sunIsUp: один
    /// расчёт на телефон и машину, а не свой цикл в каждой сцене).
    func refreshDaylight(appearance: MapAppearance, sunDay: Bool) {
        let day: Bool
        switch appearance {
        case .auto:  day = carIsDark.map { !$0 } ?? sunDay
        default:     day = appearance.isDaylight(at: nil)
        }
        if day != isDaylight { isDaylight = day }
    }
}

struct CarPlayMapScreen: View {
    @Environment(AppEnvironment.self) private var env
    let model: CarPlayMapModel

    var body: some View {
        ZStack {
            // Карта — движок, единственная подложка (11.10). В фоне окна нет:
            // картинку никто не видит, а рисует и греется телефон.
            if model.isOnScreen { engineMap } else { Theme.background.ignoresSafeArea() }

            // HUD — отдельная вью-изолятор (см. CarPlayOverlay): пер-тиковые
            // скорость/дистанции читаются там, и тик пересобирает маленький
            // HUD, а не это дерево с UIViewRepresentable карты. В фоне его
            // нет вовсе — та же экономия, что 41c4297 дал телефону: живые
            // цифры не держатся в дереве, которое никто не видит.
            if model.isOnScreen {
                // Во время выбора маршрута манёвр и прибытие — в карточке
                // вариантов системы, свой баннер их бы дублировал.
                CarPlayOverlay(showsManeuver: !model.hasSystemGuidance && !model.isPreviewing,
                               buttonInsets: model.mapButtonInsets)
            }

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
        // Отметки живости для сторожа застывания — отдельной вью: тик GPS,
        // прочитанный здесь, пересобирал бы на каждом фиксе всё дерево с
        // картой, а не крошечный невидимый пульс.
        .background { if model.isOnScreen { CarPlayLiveness(model: model) } }
        // Камера впереди — карта возвращается к машине, где бы её ни оставили.
        .onChange(of: env.location.isApproachingCamera) { _, approaching in
            if approaching { model.returnOnAlert() }
        }
        // База камер докодировалась/обновилась — «что рядом» пересчитывает
        // AppEnvironment.observeCameraRevision сразу и без экрана (холодный
        // запуск из машины: первый фикс раньше базы, машина стоит — раньше
        // здесь была своя подписка, третья на одно изменение).
        // День/ночь: тема машины приходит сразу (contentStyleDidChange в
        // делегате), солнце — из AppEnvironment.sunIsUp.
        // Солнце пересчитывает AppEnvironment (раз в 5 мин, пока на экран
        // смотрят) — здесь только следуем за ним, без своего цикла.
        .onChange(of: env.sunIsUp, initial: true) { _, day in
            model.refreshDaylight(appearance: env.settings.mapAppearance, sunDay: day)
        }
        // Настройку водитель мог сменить на телефоне посреди поездки — минуты
        // не ждём.
        .onChange(of: env.settings.mapAppearance) { _, appearance in
            model.refreshDaylight(appearance: appearance, sunDay: env.sunIsUp)
        }
    }

    @ViewBuilder private var engineMap: some View {
        #if canImport(MapLibre)
        CarPlayEngineLayer(model: model)
        #else
        Theme.background.ignoresSafeArea()
        #endif
    }
}

/// Невидимые отметки живости экрана машины для сторожа застывания
/// (CarPlaySceneDelegate.startFreezeWatch): тик GPS, на который дерево
/// перерисовалось, и пульс TimelineView, который бьёт и без GPS. Оба пишутся,
/// только пока SwiftUI действительно обновляет это окно.
private struct CarPlayLiveness: View {
    @Environment(AppEnvironment.self) private var env
    let model: CarPlayMapModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: AppConfig.carPlayHeartbeatSeconds)) { context in
            Color.clear
                .frame(width: 0, height: 0)
                .onChange(of: context.date, initial: true) { _, date in model.lastHeartbeat = date }
        }
        .onChange(of: env.location.locationTick, initial: true) { _, tick in
            model.lastRenderedTick = tick
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
