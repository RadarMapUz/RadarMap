//
//  RoadPrompts.swift
//  RadarMap
//
//  Вопросы на ходу телефона — адаптеры семи владельцев к одной очереди
//  (RoadPromptPolicy) и одной карточке (RoadPromptCard), этап 45.
//
//  Владельцы те же, что были у семи плашек, и решают то же самое: что уходит
//  на сервер и когда (MobileCameraService — «ещё стоит?», ReportFlow —
//  выбор и «Отменить», RouteService — объезд, RoadWeatherService — перевал,
//  CommuteLiveService — «опаздываю», RouteCorridorService — карта по пути).
//  Здесь только: кто хочет на экран (`RoadPromptSources`), кого показать и
//  кого молча снять (`RoadPromptDriver`), что нарисовать (`RoadPromptContent`).
//
//  Показ — вариант B: в поездке вопросом становится сама панель поездки
//  (TripLiveBar), вне поездки карточка встаёт на место прежних плашек
//  (`RoadPromptStandalone`).
//

import SwiftUI
import os

/// Вопрос, который сейчас на экране.
struct RoadPromptShown: Equatable {
    let kind: RoadPromptPolicy.Kind
    let id: String
}

// MARK: - Кто хочет на экран

@MainActor
enum RoadPromptSources {
    typealias Candidate = RoadPromptPolicy.Candidate

    /// Полный срок вопроса о проезде на экране.
    static func passTotal(voiceOver: Bool) -> TimeInterval {
        PassQuestionTimeout.seconds(voiceOver: voiceOver)
    }

    /// Срок экрана у вопросов, чьи часы ведёт экран; nil — часы владельца.
    static func ownTotal(_ kind: RoadPromptPolicy.Kind, voiceOver: Bool) -> TimeInterval? {
        switch kind {
        case .passQuestion: return passTotal(voiceOver: voiceOver)
        case .late:         return AppConfig.commuteLatePromptSeconds
        default:            return nil
        }
    }

    /// Ждущие вопросы с остатком их срока и отметкой «был вытеснен».
    ///
    /// - `yieldsCorridor`: внизу карточка итога или прибытия — мегабайты
    ///   подождут (5.9: больше двух карточек внизу не бывает).
    static func candidates(env: AppEnvironment, map: MapState, now: Date, voiceOver: Bool,
                           speedKmh: Double, yieldsCorridor: Bool,
                           freesActionBar: Bool) -> [Candidate] {
        var result: [Candidate] = []
        func clock(_ id: String) -> RoadPromptClock { map.promptClocks[id] ?? RoadPromptClock() }
        func preempted(_ id: String) -> Bool { clock(id).preempted }

        // Своё касание: выбор типа и «отправляю…» — один вопрос (панель не
        // мигает строкой поездки, пока отметка летит), «Отменить» — свой: он
        // возвращается после камеры, пока окно отмены открыто.
        let serial = env.reports.draft.serial
        switch env.reports.draft.phase {
        case .choosing, .sending:
            // Не «вытеснен» никогда: под оповещением срок выбора стоит
            // (ReportFlow.pauseChoice), и после него выбор возвращается.
            result.append(Candidate(kind: .ownTouch, id: "own-\(serial)"))
        case .sent(let sent):
            let id = "own-\(serial)-sent"
            result.append(Candidate(kind: .ownTouch, id: id, remaining: sent.undoUntil.timeIntervalSince(now),
                                    preempted: preempted(id)))
        case .idle:
            break
        }

        // Объезд: срок ведёт RouteService; снятый с экрана держит свой остаток здесь.
        if let offer = env.route.detourOffer {
            let id = "detour-\(offer.id)"
            let remaining = offer.shownAt != nil ? offer.expires.timeIntervalSince(now)
                                                 : map.promptFrozenRemaining[id]
            result.append(Candidate(kind: .detour, id: id, remaining: remaining, preempted: preempted(id)))
        }

        // «Ещё стоит?» / «Ещё перекрыто?» — один за раз, радар первым.
        if let id = passQuestionID(env) {
            let remaining = clock(id).remaining(total: passTotal(voiceOver: voiceOver), at: now)
            result.append(Candidate(kind: .passQuestion, id: id, remaining: remaining, preempted: preempted(id)))
        }

        // Погода на перевале — срок у RoadWeatherService.
        if let banner = env.roadWeather.banner {
            let id = "weather-\(banner.id)"
            result.append(Candidate(kind: .roadWeather, id: id, remaining: banner.until.timeIntervalSince(now),
                                    preempted: preempted(id)))
        }

        // «Опаздываю»: появляется стоя; показанное держится и на ходу, а
        // вытесненное ждёт следующей остановки (решает очередь).
        let live = env.commuteLive
        if let ghost = live.display, let slack = ghost.slack,
           CommuteLiveService.showsLatePlaque(slack: slack.shown, done: live.latePlaqueDone,
                                              shown: clock(lateID).wasShown,
                                              speedKmh: speedKmh, coveredByCamera: false) {
            let remaining = clock(lateID).remaining(total: AppConfig.commuteLatePromptSeconds, at: now)
            result.append(Candidate(kind: .late, id: lateID, remaining: remaining, preempted: preempted(lateID)))
        }

        // «Карта по пути»: момент решает RouteCorridor, место вне поездки —
        // CorridorOfferPlacement (обязательные кнопки колонки не уходят под неё).
        if let pending = CorridorOfferBackstage.pending(env) {
            let situation = RouteCorridor.Situation(
                routeMeters: pending.meters,
                online: env.network.isOnline,
                expensiveNetwork: env.network.isExpensive,
                // В поездке «тронулись» ловит сторож (CorridorOfferBackstage).
                moving: env.location.isProbablyDriving,
                answered: false,
                questionShown: yieldsCorridor)
            let id = "corridor-\(pending.key)"
            // Карточкой над панелью поездки, а не вместо неё: срока у вопроса
            // нет, и «Стоп» не должен прятаться, пока не ответят.
            let fits = CorridorOfferPlacement.fits(
                room: map.columnRoom, cardHeight: map.corridorCardHeight,
                shown: map.roadPrompt?.id == id,
                freed: freesActionBar ? map.actionBarHeight : 0)
            if RouteCorridor.shouldOffer(situation, offer: pending.offer), fits {
                result.append(Candidate(kind: .corridor, id: id, preempted: preempted(id)))
            }
        }
        return result
    }

    static let lateID = "late"

    /// Вопрос о проезде: радар раньше события дороги (MobileCameraService.passQuestion).
    static func passQuestionID(_ env: AppEnvironment) -> String? {
        switch env.mobile.passQuestion {
        case .camera(let camera): return "cam-\(camera.id)"
        case .road(let event):    return "road-\(event.id)"
        case nil:
            #if DEBUG
            if PassQuestionDemo.camera != nil { return "cam--1" }
            if PassQuestionDemo.road != nil { return "road--1" }
            #endif
            return nil
        }
    }
}

// MARK: - Кого показать

/// Невидимый ведущий очереди — фоном нижней стопки, места не занимает.
///
/// Читает пер-тиковые «камера на подходе» и скорость (для «опаздываю»), поэтому
/// отдельная маленькая вью (ARCHITECTURE.md, правило 13). Пишет в `MapState`
/// только смену показанного вопроса.
struct RoadPromptDriver: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    let map: MapState
    /// Оповещение о камере, скрытое кнопкой «Скрыть» (MapScreen.dismissedApproachID):
    /// оно экран больше не занимает.
    var dismissedApproachID: Int?
    /// Экран занят своим действием водителя (прицел камеры, точка на карте) —
    /// как под камерой: вопрос ждёт, отсчёт стоит.
    var blocked: Bool
    var yieldsCorridor: Bool
    var freesActionBar: Bool

    private struct Ref: Equatable {
        let kind: RoadPromptPolicy.Kind
        let id: String
    }

    /// Решение очереди без остатков сроков: они меняются каждую секунду, а
    /// обработчику нужна только смена «кого показать» и «кого снять».
    private struct Decision: Equatable {
        let shown: RoadPromptShown?
        /// Экран занят: выбор типа держит срок.
        let covered: Bool
        let expired: [Ref]
        let pending: Set<String>
    }

    private struct TimeoutKey: Equatable {
        let shown: RoadPromptShown?
        let voiceOver: Bool
    }

    var body: some View {
        let now = Date()
        let speed = env.location.speedKmh
        let candidates = RoadPromptSources.candidates(
            env: env, map: map, now: now, voiceOver: voiceOver, speedKmh: speed,
            yieldsCorridor: yieldsCorridor, freesActionBar: freesActionBar)
        let covered = RoadPromptPolicy.cameraCovers(approaching: env.location.isApproachingCamera,
                                                    cameraID: env.location.nearestCamera?.id,
                                                    dismissedID: dismissedApproachID) || blocked
        let outcome = RoadPromptPolicy.decide(
            candidates,
            covered: covered,
            standing: speed < AppConfig.commuteLatePromptMaxKmh)
        let kinds = Dictionary(candidates.map { ($0.id, $0.kind) }, uniquingKeysWith: { a, _ in a })
        let decision = Decision(
            shown: outcome.shown.map { RoadPromptShown(kind: $0.kind, id: $0.id) },
            covered: covered,
            expired: outcome.expired.compactMap { id in kinds[id].map { Ref(kind: $0, id: id) } },
            pending: Set(candidates.map(\.id)))
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: decision, initial: true) { _, new in apply(new) }
            .task(id: TimeoutKey(shown: map.roadPrompt, voiceOver: voiceOver)) { await runTimeout() }
            // Вопрос о проезде, переживший уход в фон, — не старше своего срока.
            .onAppear { env.mobile.expireStaleConfirm() }
            .onDisappear {
                // Экран ушёл (фон, другой режим низа): отсчёт встаёт, вопрос
                // вернётся по правилу вытесненного.
                if let current = map.roadPrompt { preempt(current, at: Date()) }
                map.roadPrompt = nil
                // Без экрана держать выбор некому: срок снова идёт.
                env.reports.resumeChoice()
            }
    }

    private func apply(_ decision: Decision) {
        let now = Date()
        // Выбор типа под оповещением не виден — его срок стоит, пока экран занят.
        if decision.covered { env.reports.pauseChoice(now: now) } else { env.reports.resumeChoice(now: now) }
        for ref in decision.expired { expire(ref) }
        let expiredIDs = Set(decision.expired.map(\.id))
        if map.roadPrompt != decision.shown {
            if let current = map.roadPrompt {
                if decision.pending.contains(current.id), !expiredIDs.contains(current.id) {
                    preempt(current, at: now)
                } else {
                    forget(current.id)
                }
            }
            if let shown = decision.shown { show(shown, at: now) }
            withMotion(Motion.standard) { map.roadPrompt = decision.shown }
        }
        // Ответили, истекли, сняли владельцы — их часы больше не нужны.
        for id in map.promptClocks.keys where !decision.pending.contains(id) { forget(id) }
        for id in map.promptFrozenRemaining.keys where !decision.pending.contains(id) { forget(id) }
    }

    private func show(_ shown: RoadPromptShown, at now: Date) {
        map.promptClocks[shown.id, default: RoadPromptClock()].show(at: now)
        switch shown.kind {
        case .detour:
            // Время на ответ — с момента, когда вопрос видно (как у баннера машины).
            map.promptFrozenRemaining[shown.id] = nil
            if let offer = env.route.detourOffer { env.route.noteDetourShown(id: offer.id, now: now) }
        default:
            break
        }
    }

    /// Снят с экрана, а ответа нет: часы встают, объезд запоминает остаток.
    private func preempt(_ shown: RoadPromptShown, at now: Date) {
        map.promptClocks[shown.id]?.hide(at: now)
        if shown.kind == .detour, let offer = env.route.detourOffer, offer.shownAt != nil {
            map.promptFrozenRemaining[shown.id] = offer.expires.timeIntervalSince(now)
            // RouteService не снимет его, пока он не на экране (как в машине).
            env.route.noteDetourHidden(id: offer.id, now: now)
        }
    }

    private func forget(_ id: String) {
        map.promptClocks[id] = nil
        map.promptFrozenRemaining[id] = nil
    }

    /// Снять так же, как по сроку без ответа: молчание — ничего не уходит
    /// (объезд — «остаёмся», как и было по сроку RouteService).
    private func expire(_ ref: Ref) {
        Log.app.debug("вопрос на ходу снят по сроку: \(ref.kind.description, privacy: .public)")
        switch ref.kind {
        case .passQuestion: answerPass(nil, id: ref.id)
        case .detour:       env.route.declineDetour(reason: "нет ответа")
        case .roadWeather:  env.roadWeather.hideBanner()
        case .late:         env.commuteLive.dismissLatePlaque()
        case .ownTouch, .corridor: break
        }
        forget(ref.id)
    }

    private func answerPass(_ value: Bool?, id: String) {
        guard let number = Int(id.drop { $0 != "-" }.dropFirst()) else { return }
        withMotion { env.mobile.answerPassQuestion(stillThere: value, for: number) }
    }

    /// Срок экрана у вопроса о проезде и «опаздываю», а у объезда — срок
    /// RouteService: стоя в пробке фиксов нет, и без этого карточка стояла бы
    /// с «0 сек» до следующего фикса. Истёк — снять молча.
    private func runTimeout() async {
        guard let shown = map.roadPrompt, let deadline = deadline(of: shown) else { return }
        do {
            try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
        } catch {
            // Отмена: вопрос сменился, ушёл с экрана или сменился VoiceOver
            // (новый срок уже считается) — снимать нечего.
            return
        }
        guard map.roadPrompt == shown else { return }
        expire(Ref(kind: shown.kind, id: shown.id))
    }

    private func deadline(of shown: RoadPromptShown) -> Date? {
        if shown.kind == .detour {
            return env.route.detourOffer?.shownAt?.addingTimeInterval(AppConfig.detourOfferSeconds)
        }
        guard let total = RoadPromptSources.ownTotal(shown.kind, voiceOver: voiceOver) else { return nil }
        return map.promptClocks[shown.id]?.deadline(total: total)
    }
}

// MARK: - Что нарисовать

@MainActor
enum RoadPromptContent {

    /// Карточка вопроса, который на экране; nil — его владелец уже снял вопрос.
    static func model(for shown: RoadPromptShown, env: AppEnvironment, map: MapState,
                      voiceOver: Bool, onLateShare: @escaping (String) -> Void) -> RoadPromptModel? {
        let timer: RoadPromptModel.Timer? = RoadPromptSources.ownTotal(shown.kind, voiceOver: voiceOver)
            .flatMap { total in
                map.promptClocks[shown.id]?.deadline(total: total).map { .init(deadline: $0, total: total) }
            }
        switch shown.kind {
        case .ownTouch:     return ownTouch(env)
        case .detour:       return detour(env)
        case .passQuestion: return passQuestion(env, id: shown.id, timer: timer)
        case .roadWeather:  return roadWeather(env)
        case .late:         return late(env, timer: timer, onShare: onLateShare)
        case .corridor:     return corridor(env)
        }
    }

    /// «Промолчите — ничего не отправлю» — общее для вопросов, где молчание — не ответ.
    private static var silentNothing: String { String(localized: "промолчите — ничего не отправлю") }

    // Вопрос о проезде: «Тренога ещё стоит?» / «Ещё перекрыто?».
    private static func passQuestion(_ env: AppEnvironment, id: String,
                                     timer: RoadPromptModel.Timer?) -> RoadPromptModel? {
        let mobile = env.mobile
        func thanks() {
            // Ответ должен ощущаться работой: короткое спасибо голосом — за
            // рулём на экран не смотрят.
            env.alerts.speak(String(localized: "Спасибо!"))
        }
        if let camera = cameraQuestion(env) {
            let question = MobilePassWatch.question(for: camera.kind)
            let answer: (Bool) -> Void = { value in
                withMotion { mobile.answerConfirm(stillThere: value, for: camera.id) }
                thanks()
            }
            return RoadPromptModel(
                glyph: .coin(camera.kind.glyph, fill: camera.kind.tint, ink: camera.kind.glyphTint),
                question: question.title, silence: silentNothing,
                actions: [
                    .init(id: "yes", title: question.yes, symbol: "checkmark", style: .agree,
                          spoken: question.spokenYes, perform: { answer(true) }),
                    .init(id: "no", title: question.no, symbol: "xmark",
                          spoken: question.spokenNo, perform: { answer(false) }),
                ],
                timer: timer)
        }
        if let event = roadQuestion(env) {
            let kind = ReportKind(rawValue: event.kind.rawValue) ?? .closure
            let answer: (Bool) -> Void = { value in
                withMotion { mobile.answerRoadConfirm(stillThere: value, for: event.id) }
                thanks()
            }
            return RoadPromptModel(
                glyph: .filled(kind.symbol, fill: kind.tint, ink: kind.glyphTint),
                question: RoadEventPassWatch.question(for: event.kind), silence: silentNothing,
                actions: [
                    .init(id: "yes", title: String(localized: "Да"), symbol: "checkmark", style: .agree,
                          spoken: event.kind.spokenAnswer(true), perform: { answer(true) }),
                    .init(id: "no", title: String(localized: "Нет"), symbol: "xmark",
                          spoken: event.kind.spokenAnswer(false), perform: { answer(false) }),
                ],
                timer: timer)
        }
        return nil
    }

    private static func cameraQuestion(_ env: AppEnvironment) -> (id: Int, kind: CameraType)? {
        if let camera = env.mobile.pendingConfirm { return (camera.id, camera.kind) }
        #if DEBUG
        if let kind = PassQuestionDemo.camera { return (-1, kind) }
        #endif
        return nil
    }

    private static func roadQuestion(_ env: AppEnvironment) -> (id: Int, kind: RoadEvent.Kind)? {
        if let event = env.mobile.pendingRoadConfirm { return (event.id, event.kind) }
        #if DEBUG
        if let kind = PassQuestionDemo.road { return (-1, kind) }
        #endif
        return nil
    }

    // Своё «Отметить»: выбор типа, затем «Отменить». Сроки, отправку и голос
    // ведёт ReportFlow — здесь только облик черновика.
    private static func ownTouch(_ env: AppEnvironment) -> RoadPromptModel? {
        let flow = env.reports
        switch flow.draft.phase {
        case .choosing(_, let deadline, let silence):
            let countsDown = silence == .tripod
            var actions: [RoadPromptModel.Action] = [
                .init(id: "cancel", title: String(localized: "Не отмечать"), symbol: "xmark",
                      touch: .cancel, narrow: true, perform: { flow.cancelChoice() }),
            ]
            actions += ReportKind.chosenOnTheGo.map { kind in
                let isDefault = countsDown && kind == ReportDraft.defaultKind
                return .init(id: kind.rawValue, title: ReportWords.title(kind), cameraGlyph: kind.cameraGlyph,
                             style: isDefault ? .agree : .quiet, touch: .primary,
                             pressedBySilence: isDefault, perform: { flow.choose(kind) })
            }
            return RoadPromptModel(
                glyph: .filled(Icon.reportRadar, fill: Theme.action, ink: Theme.onAction),
                question: String(localized: "Что отметить?"),
                silence: countsDown ? String(format: String(localized: "промолчите — уйдёт «%@»"),
                                             ReportWords.title(ReportDraft.defaultKind))
                                    : silentNothing,
                actions: actions, tiles: true,
                timer: countsDown ? .init(deadline: deadline, total: AppConfig.reportChooseSeconds, ownTouch: true)
                                  : nil)
        case .sent(let sent):
            return RoadPromptModel(
                glyph: .symbol("checkmark.circle.fill", tint: Theme.success),
                question: ReportWords.marked(sent.kind),
                detail: sent.queued ? String(localized: "Уйдёт, когда появится связь")
                                    : String(localized: "Увидят другие водители"),
                silence: String(localized: "промолчите — отметка останется"),
                actions: flow.canUndo() ? [
                    .init(id: "undo", title: String(localized: "Отменить"), symbol: "arrow.uturn.backward",
                          touch: .cancel, spoken: String(localized: "Отменить мою отметку"),
                          perform: { Task { _ = await flow.undo() } }),
                ] : [],
                bounces: true,
                timer: .init(deadline: sent.undoUntil, total: AppConfig.reportUndoSeconds, ownTouch: true))
        case .sending(_, let kind):
            // Отметка летит: та же карточка, без кнопок — панель не мигает
            // строкой поездки со «Стопом».
            return RoadPromptModel(
                glyph: .filled(Icon.reportRadar, fill: Theme.action, ink: Theme.onAction),
                question: ReportWords.sending(kind),
                silence: String(localized: "отметка уходит — ничего нажимать не нужно"))
        case .idle:
            return nil
        }
    }

    // Объезд пробки: решение водителя, маршрут сам не меняется.
    private static func detour(_ env: AppEnvironment) -> RoadPromptModel? {
        guard let offer = env.route.detourOffer else { return nil }
        return RoadPromptModel(
            glyph: .symbol("arrow.triangle.branch", tint: Theme.success),
            question: String(format: String(localized: "%@ — объехать?"), offer.title),
            detail: offer.subtitle,
            silence: String(localized: "промолчите — останемся на своём пути"),
            actions: [
                // Синяя, не жёлтая: жёлтая на экране одна — «Отметить».
                .init(id: "go", title: String(localized: "Объехать"), symbol: "arrow.triangle.branch",
                      style: .agree, perform: { env.route.acceptDetour(cameras: env.cameras.cameras) }),
                .init(id: "stay", title: String(localized: "Остаться"), touch: .cancel,
                      pressedBySilence: true, perform: { env.route.declineDetour() }),
            ],
            timer: offer.shownAt.map {
                .init(deadline: $0.addingTimeInterval(AppConfig.detourOfferSeconds),
                      total: AppConfig.detourOfferSeconds)
            })
    }

    // Погода на перевале: сообщение без решения — ехать ли, решает водитель.
    private static func roadWeather(_ env: AppEnvironment) -> RoadPromptModel? {
        guard let banner = env.roadWeather.banner else { return nil }
        return RoadPromptModel(
            glyph: .symbol(banner.notice.symbol, tint: Theme.warning),
            question: banner.notice.title,
            detail: banner.notice.subtitle,
            silence: String(localized: "уйдёт само"),
            actions: [
                .init(id: "ok", title: String(localized: "Понятно"), perform: { env.roadWeather.hideBanner() }),
            ],
            timer: .init(deadline: banner.until, total: AppConfig.roadWeatherBannerSeconds))
    }

    // «Опаздываю — предупредить?»: обычное сообщение от водителя, на сервер ничего.
    private static func late(_ env: AppEnvironment, timer: RoadPromptModel.Timer?,
                             onShare: @escaping (String) -> Void) -> RoadPromptModel? {
        let live = env.commuteLive
        guard let ghost = live.display else { return nil }
        // Часы — по языку приложения, как в заголовке (CommuteGhost.clock).
        let message = String(localized: "Задерживаюсь: буду примерно в \(CommuteGhost.clock(ghost.arrival)).")
        return RoadPromptModel(
            glyph: .symbol("clock.badge.exclamationmark.fill", tint: Theme.warning),
            question: GhostText.headline(ghost),
            detail: String(localized: "Предупредить, что задерживаетесь?"),
            silence: String(localized: "промолчите — никому не напишу"),
            actions: [
                .init(id: "share", title: String(localized: "Написать"), symbol: "square.and.arrow.up",
                      style: .agree, spoken: String(localized: "Предупредить"),
                      perform: {
                          live.dismissLatePlaque()
                          onShare(message)
                      }),
                .init(id: "no", title: String(localized: "Не надо"), touch: .cancel,
                      perform: { live.dismissLatePlaque() }),
            ],
            timer: timer)
    }

    // «Карта по пути без интернета»: стоя, до ответа; тронулись — не спрашиваем.
    static func corridor(_ env: AppEnvironment) -> RoadPromptModel? {
        guard let pending = CorridorOfferBackstage.pending(env) else { return nil }
        let offer = pending.offer
        let key = pending.key
        let language = OfflineMapsView.language(env.settings.appLanguage)
        var parts = RouteCorridor.shortNames(offer.regions.map { $0.title(language: language) })
        if offer.graphBytes != nil { parts.append(String(localized: "маршрут без сети")) }
        let size = Formatting.unbreakable(OfflineMapsView.size(offer.totalBytes))
        return RoadPromptModel(
            glyph: .symbol("arrow.down.circle.fill", tint: Theme.accent),
            question: String(localized: "Карта по пути без интернета"),
            detail: parts.joined(separator: " · "),
            silence: String(localized: "тронетесь — не спрошу"),
            actions: [
                // Синяя, не жёлтая: жёлтая на экране одна — «Поехали» или «Отметить».
                .init(id: "download", title: String(format: String(localized: "Скачать · %@"), size),
                      symbol: "arrow.down", style: .agree,
                      spoken: String(format: String(localized: "Скачать карту по пути, %@"),
                                     CorridorOfferText.spokenSize(offer.totalBytes)),
                      perform: {
                          guard let points = env.route.selected?.points else { return }
                          withMotion(Motion.standard) { env.corridor.download(offer, key: key, points: points) }
                      }),
                .init(id: "later", title: String(localized: "Не сейчас"), touch: .cancel,
                      perform: { withMotion(Motion.standard) { env.corridor.answer(key: key) } }),
            ])
    }
}

/// Карточка вопроса вне панели поездки — на месте прежних плашек: покой,
/// выбор маршрута до «Поехали».
struct RoadPromptStandalone: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    let map: MapState
    /// Панель поездки на экране: в неё встают все вопросы, кроме «карты по
    /// пути» — та карточкой над панелью (TripLiveBar.morphs).
    var tripBarShown = false
    let onLateShare: (String) -> Void

    var body: some View {
        Group {
            if let shown = map.roadPrompt, !tripBarShown || !TripLiveBar.morphs(shown.kind),
               let model = RoadPromptContent.model(for: shown, env: env, map: map, voiceOver: voiceOver,
                                                   onLateShare: onLateShare) {
                RoadPromptPanel { RoadPromptCard(model: model) }
                    .id(shown.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    // Карточка «Карта по пути» на экране — нижний бар уступает ей место.
                    .onAppear { if shown.kind == .corridor { map.corridorCardShown = true } }
                    .onDisappear { if shown.kind == .corridor { map.corridorCardShown = false } }
            }
        }
        .motionAnimation(Motion.standard, value: map.roadPrompt)
    }
}

/// Слова «Карты по пути», нужные и вне карточки (лист длинной поездки).
enum CorridorOfferText {
    /// «96 мегабайт» словами — VoiceOver читает «МБ» буквами.
    static func spokenSize(_ bytes: Int64, locale: Locale = NumberFormat.locale) -> String {
        let megabytes = max(1, (Double(bytes) / 1_000_000).rounded())
        return Measurement(value: megabytes, unit: UnitInformationStorage.megabytes)
            .formatted(.measurement(width: .wide, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(0)))
                .locale(locale))
    }
}

#if DEBUG
/// Скриншот-хуки вопроса о проезде без настоящего проезда (ответ уходит в
/// пустоту — ждущей отметки нет): `-demoRadarConfirm [post|accident]`,
/// `-demoRoadConfirm closure|roadwork`.
enum PassQuestionDemo {
    static var camera: CameraType? {
        let args = ProcessInfo.processInfo.arguments
        guard let at = args.firstIndex(of: "-demoRadarConfirm") else { return nil }
        switch args.indices.contains(at + 1) ? args[at + 1] : "" {
        case "post":     return .dpsPost
        case "accident": return .accident
        default:         return .tripod
        }
    }

    static var road: RoadEvent.Kind? {
        let args = ProcessInfo.processInfo.arguments
        guard let at = args.firstIndex(of: "-demoRoadConfirm") else { return nil }
        return (args.indices.contains(at + 1) ? RoadEvent.Kind(rawValue: args[at + 1]) : nil) ?? .closure
    }
}
#endif

extension RoadEvent.Kind {
    /// Ответ для VoiceOver целиком: голое «Да» не говорит, о чём.
    func spokenAnswer(_ yes: Bool) -> String {
        switch (self, yes) {
        case (.closure, true):   return String(localized: "Да, ещё перекрыто")
        case (.closure, false):  return String(localized: "Нет, уже открыто")
        case (.roadwork, true):  return String(localized: "Да, ремонт ещё идёт")
        case (.roadwork, false): return String(localized: "Нет, ремонт закончился")
        }
    }
}
