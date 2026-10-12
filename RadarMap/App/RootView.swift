//
//  RootView.swift
//  RadarMap
//
//  Корневой экран: онбординг → карта. Управляет foreground/background режимом геолокации.
//

import SwiftUI
import WidgetKit

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(Storage.Key.hasCompletedOnboarding.rawValue) private var hasCompletedOnboarding = false
    /// DEBUG `-showOnboarding`: онбординг на снимок без переустановки.
    private static var forceOnboarding: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-showOnboarding")
        #else
        false
        #endif
    }
    /// «Открыть карту на телефоне» при подключённом CarPlay (пассажиру нужны
    /// настройки и Итоги). Память сцены, не настройка: живёт до конца сессии.
    @State private var phoneMapOverride = false
    #if DEBUG
    /// Скриншот-автоматизация: CarPlay-экран на телефоне (симулятор не даёт
    /// открыть CarPlay-дисплей без ручного клика по меню).
    /// Поднимается в `.task`, а не истиной с первого кадра: cover, чей флаг
    /// уже true при первом рендере, SwiftUI показывает через раз.
    @State private var carPlayPreview = false
    /// Одна модель на весь показ: созданная в теле, она пересоздавалась бы
    /// каждой пересборкой и теряла бы и сдвиг, и масштаб.
    @State private var carPlayPreviewModel = CarPlayMapModel()
    #endif

    /// DEBUG `-handoffPreview`: экран передачи без машины — для снимков.
    #if DEBUG
    private static let previewsHandoff = ProcessInfo.processInfo.arguments.contains("-handoffPreview")
    #else
    private static let previewsHandoff = false
    #endif

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if hasCompletedOnboarding && !Self.forceOnboarding {
                // Пока едет CarPlay, телефонная карта уступает место экрану
                // передачи: MapKit на двух экранах разом — двойной нагрев,
                // а водитель смотрит на экран машины.
                if (env.isCarPlayConnected || Self.previewsHandoff) && !phoneMapOverride {
                    CarPlayHandoffView { phoneMapOverride = true }
                        .transition(.opacity)
                } else {
                    MapScreen()
                        .transition(.opacity)
                }
            } else {
                OnboardingView {
                    // Полный старт, а не только bootstrap: `.task` корня уже
                    // отработал и вышел по guard hasCompletedOnboarding, а
                    // второй раз он не выполнится — идентичность ZStack при
                    // смене флага не меняется. Без этого ПЕРВАЯ сессия жила в
                    // тихом фоне: без опроса отметок, без CoreMotion и без
                    // отметки «экран на виду».
                    env.startDrivingServices()
                    env.location.setForeground(true)
                    env.setPhoneSceneActive(true)
                    withMotion(.easeInOut) { hasCompletedOnboarding = true }
                }
                .transition(.opacity)
            }
        }
        // Оценка App Store — на корне, а не на MapScreen: за рулём CarPlay
        // экран телефона показывает экран передачи, MapScreen не смонтирован,
        // и конец поездки (единственный триггер) никто не видел — просьба об
        // оценке была недостижима ровно для самого лояльного сегмента.
        .modifier(ReviewPromptModifier())
        .motionAnimation(Motion.standard, value: env.isCarPlayConnected)
        // Вышли из машины — следующее подключение снова начнёт с экрана передачи.
        .onChange(of: env.isCarPlayConnected) { _, connected in
            if !connected { phoneMapOverride = false }
        }
        // Виджет локскрина: radarmap://start-trip — поездка одним тапом с
        // заблокированного экрана. Активную поездку диплинк никогда не трогает.
        .onOpenURL { url in
            guard url.scheme == "radarmap", url.host() == "start-trip",
                  !env.location.isTripActive else { return }
            env.location.startTrip()
        }
        #if DEBUG
        .fullScreenCover(isPresented: $carPlayPreview) {
            // Экран машины в настоящем размере (800×480, с `-carplayWide` —
            // широкий 1280×480): раскладку HUD видно такой, какой её увидит
            // машина, а не растянутой на портретный экран. На портретном
            // телефоне кадр повёрнут на 90° — так он вдвое крупнее, и
            // скриншот достаточно повернуть обратно.
            GeometryReader { geometry in
                let wide = ProcessInfo.processInfo.arguments.contains("-carplayWide")
                let size = CGSize(width: wide ? 1280 : 800, height: 480)
                let portrait = geometry.size.height > geometry.size.width
                let room = portrait
                    ? CGSize(width: geometry.size.height, height: geometry.size.width)
                    : geometry.size
                let scale = min(room.width / size.width, room.height / size.height)
                CarPlayMapScreen(model: carPlayPreviewModel)
                    .environment(env)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .scaleEffect(scale)
                    .rotationEffect(portrait ? .degrees(90) : .zero)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .ignoresSafeArea()
            .background(Color.black)
            // Команды шаблона машины без машины: -carplayPan шлёт сдвиг
            // стрелкой, как CPMapTemplate, — видно, едет ли карта.
            .task {
                guard ProcessInfo.processInfo.arguments.contains("-carplayPan") else { return }
                await Task.pause(seconds: 8)
                for _ in 0..<4 {
                    carPlayPreviewModel.pan(by: CGSize(width: -AppConfig.carPlayPanStep, height: 0))
                    await Task.pause(seconds: 1.5)
                }
            }
        }
        #endif
        // Тема по солнцу: закат не ждёт перезапуска. Раз в пять минут — дешёвый
        // расчёт NOAA без подписки на тик GPS (её корню иметь нельзя).
        .task {
            while !Task.isCancelled {
                env.refreshInterfaceAppearance()
                await Task.pause(seconds: 300)
            }
        }
        .onChange(of: env.settings.mapAppearance) { _, _ in
            env.refreshInterfaceAppearance()
        }
        .task {
            #if DEBUG
            // Экран передачи без машины: проверить глазами на симуляторе.
            if ProcessInfo.processInfo.arguments.contains("-carplayConnected") {
                env.setCarPlayConnected(true)
            }
            if ProcessInfo.processInfo.arguments.contains("-carplayPreview") {
                Task {
                    await Task.pause(seconds: 1)
                    // В машине «на экране» ставит делегат сцены по её
                    // состоянию; у предпросмотра сцены нет — он на экране сразу.
                    carPlayPreviewModel.isOnScreen = true
                    carPlayPreview = true
                }
            }
            #endif
            // Общий набор сервисов вождения — см. startDrivingServices:
            // CarPlay может подключиться раньше телефонной сцены.
            env.startDrivingServices()
            guard hasCompletedOnboarding else { return }
            env.location.setForeground(true)
            // И здесь тоже, а не только в onChange(of: scenePhase): SwiftUI не
            // присылает onChange для НАЧАЛЬНОГО значения фазы, поэтому у
            // прошедшего онбординг флаг оставался false до первого честного
            // круга «свернул-развернул». А на нём стоит остановка опроса
            // отметок: поездка, которая на холодном старте сама началась по
            // CoreMotion и сама кончилась, гасила опрос треног, пока карта
            // всё это время была на переднем плане.
            env.setPhoneSceneActive(true)
        }
        .onChange(of: scenePhase) { _, phase in
            guard hasCompletedOnboarding else { return }
            switch phase {
            case .active:
                env.refreshInterfaceAppearance()
                env.location.setForeground(true)
                env.setPhoneSceneActive(true)   // опрос радаров: жив любой экран
                env.motion.start()
                // Пульт, правки модератора и база камер проверялись только на
                // ХОЛОДНОМ старте: телефон живёт неделями без перезапуска
                // приложения, и стоп-кран, включённый вчера, доезжал бы до
                // такого пользователя лишь после ручного убийства процесса.
                // Свои интервалы (6 ч / 3 ч / сутки) сервисы держат сами.
                env.refreshRemoteIfNeeded()
            case .background:
                env.location.setForeground(false)   // в поездке непрерывный GPS продолжит работать
                env.setPhoneSceneActive(false)       // опрос гаснет, если и CarPlay нет
                snapshotForWidget()
            case .inactive:
                // Шторка, Пункт управления, Face ID, переключатель приложений:
                // .inactive прилетает на каждое мелкое прерывание и дважды на
                // каждый честный круг «свернул-развернул». Гасить здесь GPS и
                // перезагружать виджеты — значит обнулять спидометр от свайпа
                // шторки и жечь бюджет обновлений виджета по нескольку раз на
                // переключение. Настоящий уход — только .background.
                break
            @unknown default:
                break
            }
        }
    }

    /// Снимок данных для домашнего виджета (через App Group). Сам расчёт — в
    /// AppEnvironment: тот же снимок пишется и в конце поездки, писателей два,
    /// а формула обязана быть одна.
    private func snapshotForWidget() {
        env.refreshWidgetSnapshot()
    }
}
