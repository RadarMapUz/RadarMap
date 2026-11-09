//
//  ReportDraft.swift
//  RadarMap
//
//  Черновик отметки водителя — от первого касания до конца окна «Отменить»
//  (вариант B, выбор владельца 02.11: docs/team/specs/tripod-report.md).
//
//  Касание «Отметить» ничего не отправляет: оно запоминает точку, время,
//  скорость и курс и открывает выбор — Тренога (выбрана), Пост ДПС, ДТП и «✕».
//  Молчание три секунды отправляет треногу, второе касание той же кнопки —
//  тоже треногу сразу, «✕» — не отправляет ничего. Ошибочное касание поэтому
//  не попадает в общую базу вовсе: отменять приходится то, что ещё не ушло.
//
//  Черновик один на все входы — кнопку телефона, бар и кнопку карты в машине,
//  часы, плашку и Siri. Раньше у каждого был свой флаг «в полёте», и два
//  касания с разных входов уходили двумя точками; здесь отправка одна на всех
//  (`isInFlight`), а тип, названный с другого входа (Siri «Пост здесь»),
//  закрывает открытый выбор этим типом и той самой первой точкой.
//
//  Точка — из МОМЕНТА КАСАНИЯ, а не отправки: за три секунды выбора на 60 км/ч
//  машина уезжает на 50 м, и отметка встала бы за треногой — там, где она уже
//  никого не предупредит. По той же причине `ReportGuard` проверяет точку один
//  раз, при касании: стоя у светофора к концу отсчёта, «с дивана» отказал бы
//  тому, кто нажал на ходу.
//
//  Чистая логика без часов внутри: время всегда приходит параметром.
//  Покрыто ReportDraftTests.
//

import CoreLocation
import Foundation

nonisolated struct ReportDraft: Equatable {

    /// Откуда касание. От входа зависят две вещи: есть ли у него выбор типа и
    /// сколько секунд прошло между «увидел» и «нажал» (поправка места, A4).
    enum Source: String, Equatable, Sendable {
        /// Кнопка «Отметить» в панели поездки.
        case phone
        /// Та же кнопка на экране оповещения о камере: экран занят камерой,
        /// выбор не встаёт — тренога уходит сразу.
        case phoneAlert
        /// Кнопка в баре CarPlay.
        case carBar
        /// Круглая кнопка карты в машине.
        case carMap
        case watch
        case liveActivity
        case siri

        /// Показывает ли вход выбор. Часам, плашке и Siri показать его негде:
        /// тренога уходит сразу, «Отменить» — после.
        var offersChoice: Bool {
            switch self {
            case .phone, .carBar, .carMap: return true
            case .phoneAlert, .watch, .liveActivity, .siri: return false
            }
        }

        /// Секунды от «увидел» до касания. Кнопка, машина и часы — общая
        /// реакция; Siri — плюс фраза и её распознавание.
        var reactionSeconds: TimeInterval {
            switch self {
            case .siri: return AppConfig.reportReactionSeconds + AppConfig.reportSiriExtraSeconds
            default:    return AppConfig.reportReactionSeconds
            }
        }

        /// Сколько ждать годной точки, если её нет в момент касания. Часы,
        /// плашка и Siri будят приложение из фона — там точке нужно больше.
        var fixWaitSeconds: TimeInterval {
            switch self {
            case .watch, .liveActivity, .siri: return AppConfig.reportRemoteFixWaitSeconds
            default:                            return AppConfig.reportNoFixWaitSeconds
            }
        }
    }

    /// Мгновение касания: всё, что уйдёт на сервер, берётся отсюда.
    struct Touch: Equatable {
        /// Место отметки — уже сдвинутое по своему треку на время реакции.
        var latitude: Double
        var longitude: Double
        var speedKmh: Double
        /// Курс, 0…360; < 0 — неизвестен.
        var course: Double
        var isTripActive: Bool
        var fix: ReportGuard.Fix?
        var at: Date
        var source: Source

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    /// Что сделает молчание до конца отсчёта.
    enum Silence: Equatable {
        /// Обычный выбор: молчание — тренога.
        case tripod
        /// Водитель уже сказал «не тренога» (сетка CarPlay до iOS 27):
        /// молчание — не отправлять ничего.
        case nothing
    }

    /// Ушедшая отметка и её окно «Отменить».
    struct Sent: Equatable {
        var kind: ReportKind
        /// Серверный id своей новой точки; nil — точку отменить нельзя
        /// (влилась в чужую) или она ещё в очереди.
        var serverID: Int?
        /// Ждёт связи в очереди — «Отменить» снимает её оттуда.
        var queued: Bool
        /// Время касания: им отметка помечена в очереди.
        var touchedAt: Date
        var undoUntil: Date

        var canUndo: Bool { serverID != nil || queued }
    }

    enum Phase: Equatable {
        case idle
        case choosing(Touch, deadline: Date, silence: Silence)
        case sending(Touch, kind: ReportKind)
        case sent(Sent)
    }

    /// Что делать вызывающему после шага.
    enum Effect: Equatable {
        case none
        /// Отметка уже летит — касание проглочено, второй точки не будет.
        case busy
        /// Отказ по точке касания — голосом и вспышкой, черновика нет.
        case refused(ReportGuard.Refusal)
        /// Показать выбор до `deadline`.
        case choose(deadline: Date)
        /// Отправить этот тип по этой точке.
        case send(Touch, ReportKind)
        /// Выбор закрыт без отправки — «Не отмечено».
        case cancelled
    }

    /// Тип по умолчанию: главный случай владельца — тренога.
    static let defaultKind: ReportKind = .tripod

    private(set) var phase: Phase = .idle
    /// Номер черновика: машина и плитки узнают «свой» выбор и не показывают
    /// его дважды.
    private(set) var serial = 0
    /// Остаток срока выбора, пока экран телефона занят оповещением о камере
    /// (этап 45); nil — часы идут. Выбор под оповещением не виден, и тренога
    /// не должна уходить молчанием, которого водитель не мог прервать «✕».
    private(set) var pausedLeft: TimeInterval?

    // MARK: - Состояние

    var isInFlight: Bool {
        if case .sending = phase { return true }
        return false
    }

    var choosing: (touch: Touch, deadline: Date, silence: Silence)? {
        if case .choosing(let touch, let deadline, let silence) = phase { return (touch, deadline, silence) }
        return nil
    }

    var sent: Sent? {
        if case .sent(let sent) = phase { return sent }
        return nil
    }

    // MARK: - Шаги

    /// Касание «Отметить». `showsChoice` — вход может показать выбор прямо
    /// сейчас (у машины — если на экране не камера). `refusal` — проверка
    /// `ReportGuard` по этой же точке. `shownAt` — когда выбор встанет на
    /// экран: точка и время касания — от касания (по ним сдвиг), а три
    /// секунды выбора — от показа. Ожидание годной точки (до 3 с в пробке у
    /// поста) иначе съедало окно целиком, и «✕» нажать было нельзя (ревью 40b, Н2).
    mutating func tap(_ touch: Touch, refusal: ReportGuard.Refusal?, showsChoice: Bool,
                      shownAt: Date? = nil,
                      chooseSeconds: TimeInterval = AppConfig.reportChooseSeconds) -> Effect {
        switch phase {
        case .sending:
            return .busy
        case .choosing(let first, _, _):
            // «Тап-тап» вслепую — тренога сразу и по ПЕРВОЙ точке: второе
            // касание — подтверждение, а не новое место.
            phase = .sending(first, kind: Self.defaultKind)
            return .send(first, Self.defaultKind)
        case .idle, .sent:
            // Отказ не трогает прошлую отметку: её «Отменить» ещё работает.
            if let refusal { return .refused(refusal) }
            serial &+= 1
            guard showsChoice else {
                phase = .sending(touch, kind: Self.defaultKind)
                return .send(touch, Self.defaultKind)
            }
            let deadline = max(touch.at, shownAt ?? touch.at).addingTimeInterval(chooseSeconds)
            phase = .choosing(touch, deadline: deadline, silence: .tripod)
            pausedLeft = nil
            return .choose(deadline: deadline)
        }
    }

    /// Тип выбран в открытом выборе.
    mutating func choose(_ kind: ReportKind) -> Effect {
        guard case .choosing(let touch, _, _) = phase else { return .none }
        phase = .sending(touch, kind: kind)
        return .send(touch, kind)
    }

    /// Тип назван прямо с другого входа (Siri «Пост здесь», действие
    /// VoiceOver). Открытый выбор закрывается этим типом и своей первой
    /// точкой; без выбора — обычная отметка по `touch`.
    mutating func explicit(_ kind: ReportKind, touch: Touch, refusal: ReportGuard.Refusal?) -> Effect {
        switch phase {
        case .sending:
            return .busy
        case .choosing(let first, _, _):
            phase = .sending(first, kind: kind)
            return .send(first, kind)
        case .idle, .sent:
            if let refusal { return .refused(refusal) }
            serial &+= 1
            phase = .sending(touch, kind: kind)
            return .send(touch, kind)
        }
    }

    /// «✕» до отправки: не уходит ничего.
    mutating func cancel() -> Effect {
        guard case .choosing = phase else { return .none }
        phase = .idle
        return .cancelled
    }

    /// Отсчёт стоит, пока водитель выбирает в сетке (CarPlay до iOS 27): он
    /// уже сказал «не тренога», и молчание теперь не отправляет ничего.
    mutating func hold(until deadline: Date) {
        guard case .choosing(let touch, _, _) = phase else { return }
        phase = .choosing(touch, deadline: deadline, silence: .nothing)
        pausedLeft = nil
    }

    /// Экран занят оповещением о камере: срок выбора встаёт с тем, что
    /// осталось. false — останавливать нечего (не выбор или уже стоит).
    mutating func pause(now: Date) -> Bool {
        guard pausedLeft == nil, case .choosing(_, let deadline, _) = phase else { return false }
        pausedLeft = max(0, deadline.timeIntervalSince(now))
        return true
    }

    /// Экран освободился: выбор возвращается с прежним остатком, но не меньше
    /// `minimum` — за полсекунды «✕» не нажать. nil — возвращать нечего.
    mutating func resume(now: Date, minimum: TimeInterval) -> Date? {
        guard let left = pausedLeft else { return nil }
        pausedLeft = nil
        guard case .choosing(let touch, _, let silence) = phase else { return nil }
        let deadline = now.addingTimeInterval(max(left, minimum))
        phase = .choosing(touch, deadline: deadline, silence: silence)
        return deadline
    }

    /// Такт часов: вышел ли срок выбора.
    mutating func expire(now: Date) -> Effect {
        guard pausedLeft == nil,
              case .choosing(let touch, let deadline, let silence) = phase, now >= deadline else { return .none }
        switch silence {
        case .tripod:
            phase = .sending(touch, kind: Self.defaultKind)
            return .send(touch, Self.defaultKind)
        case .nothing:
            phase = .idle
            return .cancelled
        }
    }

    /// Ответ сервера (или очереди) на отправку. `serverID` — своя новая
    /// точка; nil у влитой в чужую. Неудача — черновика больше нет.
    mutating func finished(delivered: Bool, serverID: Int?, queued: Bool, now: Date,
                           undoSeconds: TimeInterval = AppConfig.reportUndoSeconds) {
        guard case .sending(let touch, let kind) = phase else { return }
        guard delivered else {
            phase = .idle
            return
        }
        phase = .sent(Sent(kind: kind, serverID: serverID, queued: queued, touchedAt: touch.at,
                           undoUntil: now.addingTimeInterval(undoSeconds)))
    }

    /// Окно «Отменить» вышло. true — закрыто сейчас.
    @discardableResult
    mutating func closeUndo(now: Date) -> Bool {
        guard case .sent(let sent) = phase, now >= sent.undoUntil else { return false }
        phase = .idle
        return true
    }

    /// «Отменить» нажата — отметки больше нет (или её отзыв ушёл).
    mutating func undone() {
        guard case .sent = phase else { return }
        phase = .idle
    }

    /// Сколько окна «Отменить» осталось.
    func undoRemaining(now: Date) -> TimeInterval {
        guard let sent else { return 0 }
        return max(0, sent.undoUntil.timeIntervalSince(now))
    }
}

extension ReportKind {
    /// Что предлагает выбор на ходу (плитки телефона, баннер машины):
    /// тренога — первой и выбранной, пост и ДТП — вторым касанием. Радар —
    /// голосом (Siri): на сервере он одна семья с треногой, и при слиянии
    /// побеждает тренога.
    nonisolated static var chosenOnTheGo: [ReportKind] { [.tripod, .post, .accident] }
}

/// Слова отметки — одни на телефоне, в машине, на часах и в голосе. Род у
/// каждого типа свой, поэтому и ключи свои («Пост ДПС отмечен», «Тренога
/// отмечена»), а не «%@ отмечен(а)».
nonisolated enum ReportWords {

    /// Короткое имя типа по словарю (маркетолог, 02.11): Радар / Тренога /
    /// Пост ДПС / ДТП; uz Radar / Uch oyoq / YPX posti / YTH. Длинное
    /// «Передвижной радар» остаётся в карточке камеры — там есть место.
    static func title(_ kind: ReportKind) -> String {
        switch kind {
        case .radar:    return String(localized: "Радар")
        case .tripod:   return String(localized: "Тренога")
        case .post:     return String(localized: "Пост ДПС")
        case .accident: return String(localized: "ДТП")
        case .closure:  return String(localized: "Перекрыто")
        case .roadwork: return String(localized: "Ремонт")
        }
    }

    /// «Тренога отмечена» — голос и баннер после отправки.
    static func marked(_ kind: ReportKind) -> String {
        switch kind {
        case .radar:    return String(localized: "Радар отмечен")
        case .tripod:   return String(localized: "Тренога отмечена")
        case .post:     return String(localized: "Пост ДПС отмечен")
        case .accident: return String(localized: "ДТП отмечено")
        case .closure, .roadwork: return String(localized: "Отмечено")
        }
    }

    /// Отметка летит — на баннере машины вместо кнопок выбора.
    static func sending(_ kind: ReportKind) -> String {
        String(format: String(localized: "%@ — отправляю…"), title(kind))
    }

    /// Открыли выбор — голосом, если на экран не смотрят.
    static var choosePrompt: String { String(localized: "Что отметить?") }
    /// Короткий вариант заголовка выбора (узкий экран машины).
    static var choosePromptShort: String { String(localized: "Отметить?") }
    /// «✕» до отправки.
    static var notMarked: String { String(localized: "Не отмечено") }
}
