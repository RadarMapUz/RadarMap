//
//  ReportFlow.swift
//  RadarMap
//
//  Отметка водителя от касания до «Отменить» — один исполнитель черновика
//  (ReportDraft) для телефона, машины, часов, плашки и Siri.
//
//  Черновик — чистая модель; здесь то, что ей нужно от мира: снимок точки в
//  момент касания (сдвинутый по своему треку, ReportTrack), часы отсчёта и
//  окна отмены, отправка через единственную дверь `quickReport` и голос.
//  Плитки телефона и баннер машины только показывают `draft` и зовут
//  `choose` / `cancelChoice` / `undo` — своих флагов и таймеров у них нет,
//  поэтому касание в машине и на телефоне — один и тот же черновик.
//
//  Отдельным сервисом, а не внутри MobileCameraService: тот отвечает за сеть
//  и списки отметок (и уже за тысячу строк), а здесь — разговор с водителем.
//

import CoreLocation
import Foundation
import Observation
import os

@MainActor
@Observable
final class ReportFlow {
    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей
    /// (см. MobileCameraService).
    nonisolated deinit {}

    private(set) var draft = ReportDraft()

    @ObservationIgnored weak var mobile: MobileCameraService?
    @ObservationIgnored weak var location: LocationService?
    @ObservationIgnored weak var alerts: AlertPlayer?

    /// Ждём годную точку после касания — второе касание в это время не
    /// заводит второй черновик, а кнопка показывает «Ищу GPS» (до 3 с).
    private(set) var awaitingFix = false
    @ObservationIgnored private var choiceTimer: Task<Void, Never>?
    @ObservationIgnored private var undoTimer: Task<Void, Never>?

    /// Чем кончилось касание — для вспышки на кнопке, часов и плашки.
    enum Answer {
        /// Уже идёт отправка или ждём точку — касание проглочено.
        case busy
        /// Открыт выбор: отправит отсчёт, выбор или второе касание.
        case choosing
        /// Выбор закрыт «✕» — не ушло ничего.
        case cancelled
        /// Отправлено (или отказ — внутри итога).
        case done(MobileCameraService.QuickOutcome)

        /// Точка на карте есть или будет: для ✓ там, где голоса не ждут.
        var pointExists: Bool? {
            switch self {
            case .busy: return nil
            case .choosing: return true
            case .cancelled: return false
            case .done(let outcome): return outcome.pointExists
            }
        }
    }

    // MARK: - Входы

    /// Касание «Отметить» (или «Радар!» с часов и плашки). `choiceBlocked` —
    /// выбор сейчас не показать: в машине на экране баннер камеры, и камера
    /// всегда сверху — тогда тренога уходит сразу.
    @discardableResult
    func begin(from source: ReportDraft.Source, choiceBlocked: Bool = false,
               speak: Bool = true) async -> Answer {
        // Второе касание во время выбора — тренога сразу, по первой точке.
        if draft.choosing != nil {
            let effect = draft.tap(placeholderTouch(source), refusal: nil, showsChoice: false)
            return await perform(effect, speak: speak)
        }
        guard !draft.isInFlight, !awaitingFix else { return .busy }
        let tappedAt = Date()
        awaitingFix = true
        let touch = await snapshot(source: source, at: tappedAt)
        awaitingFix = false
        let refusal = refusalFor(touch, kind: ReportDraft.defaultKind)
        // Три секунды выбора — от показа, а не от касания (Н2).
        let effect = draft.tap(touch, refusal: refusal,
                               showsChoice: source.offersChoice && !choiceBlocked, shownAt: Date())
        return await perform(effect, speak: speak)
    }

    /// Тип назван прямо (Siri «Пост здесь», действие VoiceOver): открытый
    /// выбор закрывается этим типом, без выбора — обычная отметка.
    @discardableResult
    func report(_ kind: ReportKind, from source: ReportDraft.Source, speak: Bool = true) async -> Answer {
        if draft.choosing != nil {
            return await perform(draft.explicit(kind, touch: placeholderTouch(source), refusal: nil), speak: speak)
        }
        guard !draft.isInFlight, !awaitingFix else { return .busy }
        let tappedAt = Date()
        awaitingFix = true
        let touch = await snapshot(source: source, at: tappedAt)
        awaitingFix = false
        return await perform(draft.explicit(kind, touch: touch, refusal: refusalFor(touch, kind: kind)),
                             speak: speak)
    }

    /// Плитка или кнопка баннера: этот тип.
    func choose(_ kind: ReportKind) {
        let effect = draft.choose(kind)
        Task { await perform(effect, speak: true) }
    }

    /// «✕» до отправки.
    func cancelChoice() {
        let effect = draft.cancel()
        Task { await perform(effect, speak: true) }
    }

    /// Машина до iOS 27 открыла сетку «Пост ДПС / ДТП»: отсчёт треноги
    /// стоит, а сетка без выбора закрывается, ничего не отправив.
    func holdChoice() {
        guard draft.choosing != nil else { return }
        let deadline = Date().addingTimeInterval(AppConfig.reportGridIdleSeconds)
        draft.hold(until: deadline)
        armChoiceTimer(deadline)
    }

    /// Экран телефона занят оповещением о камере (RoadPromptDriver): срок
    /// выбора стоит — выбор под оповещением не виден.
    func pauseChoice(now: Date = Date()) {
        guard draft.pause(now: now) else { return }
        choiceTimer?.cancel()
    }

    /// Экран освободился: выбор возвращается с остатком срока, не меньше
    /// `reportChooseResumeSeconds`.
    func resumeChoice(now: Date = Date()) {
        guard let deadline = draft.resume(now: now, minimum: AppConfig.reportChooseResumeSeconds) else { return }
        armChoiceTimer(deadline)
    }

    /// Можно ли сейчас отменить ушедшую отметку.
    func canUndo(now: Date = Date()) -> Bool {
        guard let sent = draft.sent, sent.canUndo, now < sent.undoUntil else { return false }
        // Точку уже подтвердил другой водитель — сервер откажет.
        if let id = sent.serverID { return mobile?.cancellableReportID(now: now) == id }
        return true
    }

    /// «Отменить»: своя новая точка — отзыв на сервере, ждущая связи —
    /// снять из очереди. Возвращает сказанную фразу.
    @discardableResult
    func undo(speak: Bool = true) async -> String {
        guard let sent = draft.sent, canUndo(), let mobile else { return "" }
        draft.undone()
        undoTimer?.cancel()
        let why: MobileCameraService.ReportResult.Failure?
        if let id = sent.serverID {
            why = await mobile.cancelReport(id: id)
        } else {
            // Из очереди: снять оттуда, дождаться летящей досылки или отозвать
            // уже ушедшую по id (MobileCameraService.cancelQueued).
            why = await mobile.cancelQueued(touchedAt: sent.touchedAt)
        }
        let text = why?.spoken ?? String(localized: "Отметка убрана")
        Log.network.notice("отметка отменена водителем")
        if speak { alerts?.speak(text) }
        return text
    }

    /// «Отмени отметку» голосом: последняя своя отметка в окне СЕРВЕРА
    /// (`cancellableReportID`, 10 мин), а не в 8-секундном окне экрана. Ждущая
    /// связи — как «Отменить» на экране. nil — отменять нечего.
    func undoLatest(speak: Bool = true) async -> String? {
        if canUndo() { return await undo(speak: speak) }
        guard let mobile, let id = mobile.cancellableReportID() else { return nil }
        if draft.sent?.serverID == id {
            draft.undone()
            undoTimer?.cancel()
        }
        let text = await mobile.cancelReport(id: id)?.spoken ?? String(localized: "Отметка убрана")
        if speak { alerts?.speak(text) }
        return text
    }

    // MARK: - Исполнение

    @discardableResult
    private func perform(_ effect: ReportDraft.Effect, speak: Bool) async -> Answer {
        switch effect {
        case .none:
            return .busy
        case .busy:
            return .busy
        case .refused(let why):
            let outcome = MobileCameraService.QuickOutcome.refused(why)
            if speak { alerts?.speak(outcome.spoken) }
            return .done(outcome)
        case .choose(let deadline):
            armChoiceTimer(deadline)
            // Голос подсказки не перебивает голос камеры: впереди камера —
            // молчим, плитки и отсчёт остаются (CarPlay, A7).
            if speak, location?.isApproachingCamera != true { alerts?.speak(ReportWords.choosePrompt) }
            return .choosing
        case .cancelled:
            choiceTimer?.cancel()
            if speak { alerts?.speak(ReportWords.notMarked) }
            return .cancelled
        case .send(let touch, let kind):
            choiceTimer?.cancel()
            return .done(await send(touch, kind: kind, speak: speak))
        }
    }

    private func send(_ touch: ReportDraft.Touch, kind: ReportKind,
                      speak: Bool) async -> MobileCameraService.QuickOutcome {
        guard let mobile else {
            draft.finished(delivered: false, serverID: nil, queued: false, now: Date())
            return .sent(.failed(.disabled))
        }
        let outcome = await mobile.quickReport(kind: kind, coordinate: touch.coordinate,
                                               speedKmh: touch.speedKmh, isTripActive: touch.isTripActive,
                                               placement: .blind, fix: touch.fix, course: touch.course,
                                               touchedAt: touch.at)
        var queued = false
        var serverID: Int?
        switch outcome {
        case .sent(.created): serverID = mobile.lastSentID
        case .queued: queued = true
        default: break
        }
        draft.finished(delivered: outcome.isSuccess, serverID: serverID, queued: queued, now: Date())
        if let sent = draft.sent { armUndoTimer(sent.undoUntil) }
        Log.network.notice("отметка (\(touch.source.rawValue, privacy: .public)): \(kind.rawValue, privacy: .public) — \(outcome.isSuccess ? "ушла" : "нет", privacy: .public)")
        if speak { alerts?.speak(outcome.spoken(for: kind)) }
        return outcome
    }

    // MARK: - Точка касания

    /// Снимок мгновения касания. Нет годной точки — ждём до срока входа;
    /// время касания остаётся прежним (сдвиг считается от него).
    private func snapshot(source: ReportDraft.Source, at tappedAt: Date) async -> ReportDraft.Touch {
        if let location, !ReportGuard.isTrusted(location.reportFix) {
            _ = await location.awaitReportCoordinate(timeout: source.fixWaitSeconds)
        }
        guard let location, let raw = location.currentCoordinate else {
            return ReportDraft.Touch(latitude: 0, longitude: 0, speedKmh: 0, course: -1, isTripActive: false,
                                     fix: location?.reportFix, at: tappedAt, source: source)
        }
        let origin = ReportTrack.origin(points: location.reportTrack.points, touch: tappedAt,
                                        reaction: source.reactionSeconds, coordinate: raw,
                                        course: location.currentCourse, speedKmh: location.speedKmh)
        // Курс — отрезка трека в точке сдвига, а не касания (Н6): он уходит в
        // снап и на сервер.
        return ReportDraft.Touch(latitude: origin.latitude, longitude: origin.longitude,
                                 speedKmh: location.speedKmh, course: origin.course,
                                 isTripActive: location.isTripActive, fix: location.reportFix,
                                 at: tappedAt, source: source)
    }

    /// Касание, когда выбор уже открыт: его точка не нужна — черновик берёт
    /// первую.
    private func placeholderTouch(_ source: ReportDraft.Source) -> ReportDraft.Touch {
        ReportDraft.Touch(latitude: 0, longitude: 0, speedKmh: 0, course: -1, isTripActive: false,
                          fix: nil, at: Date(), source: source)
    }

    private func refusalFor(_ touch: ReportDraft.Touch, kind: ReportKind) -> ReportGuard.Refusal? {
        let point: CLLocationCoordinate2D? = touch.latitude == 0 && touch.longitude == 0 ? nil : touch.coordinate
        return ReportGuard.check(kind: kind, coordinate: point, speedKmh: touch.speedKmh,
                                 isTripActive: touch.isTripActive, placement: .blind, fix: touch.fix,
                                 lastSent: mobile?.lastSent, now: touch.at)
    }

    // MARK: - Часы

    private func armChoiceTimer(_ deadline: Date) {
        choiceTimer?.cancel()
        choiceTimer = Task { [weak self] in
            // Ошибка sleep — только отмена задачи: выбор сделан раньше срока.
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            // Сон кончается не секунда в секунду — срок считаем наступившим.
            await self.perform(self.draft.expire(now: max(Date(), deadline)), speak: true)
        }
    }

    private func armUndoTimer(_ until: Date) {
        undoTimer?.cancel()
        undoTimer = Task { [weak self] in
            // Ошибка sleep — только отмена задачи: отменили раньше срока.
            try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            self.draft.closeUndo(now: max(Date(), until))
        }
    }
}
