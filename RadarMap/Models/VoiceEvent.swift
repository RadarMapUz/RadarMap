//
//  VoiceEvent.swift
//  RadarMap
//
//  Что сказать голосом — ТИПОМ, а не строкой (этап 16, записанный голос).
//
//  Синтезатору хватает готовой фразы: он читает любой текст. Записанному
//  голосу текст не помогает — у него есть только отрывки, которые диктор
//  произнёс в студии, и собрать «Statsionar radar oldinda oʻngda, besh yuz
//  metr» он может, лишь зная, ИЗ ЧЕГО фраза: тип камеры, сторона, расстояние.
//  Поэтому каждая реплика за рулём описана здесь событием, а `VoiceComposer`
//  превращает событие в список отрывков на нужном языке.
//
//  Список событий выведен из 104 шаблонов `docs/voice_phrases_uz.md` и из
//  кода, который говорит сегодня (камеры, манёвры, лимиты, пробки, отметки,
//  ответы на «Радар!»). Фразы с именем собственным (улица, название
//  остановки) событием не описываются вовсе: записать все улицы нельзя, и
//  такая фраза целиком идёт синтезатором — половины фразы не бывает.
//
//  Файл намеренно самодостаточен (только Foundation): его же собирает
//  `tools/voice_kit/export_script.sh`, чтобы выдать сценарий диктору.
//

import Foundation

/// Язык записанного голоса.
nonisolated enum VoiceLanguage: String, CaseIterable, Sendable {
    case ru, uz
}

/// Имя записанного отрывка — оно же имя файла в пакете (`<id>.wav` у диктора,
/// `<id>.m4a` в приложении). Только латиница в нижнем регистре, цифры, точка
/// и подчёркивание: имя проходит через файловую систему студии, git и бандл.
nonisolated struct SegmentID: Hashable, Comparable, Sendable, ExpressibleByStringLiteral,
                              CustomStringConvertible {
    let raw: String

    init(_ raw: String) { self.raw = raw }
    init(stringLiteral value: String) { raw = value }

    var description: String { raw }

    static func < (a: SegmentID, b: SegmentID) -> Bool { a.raw < b.raw }

    /// Пауза на месте запятой или двоеточия. Не записывается: тишину нужной
    /// длины плеер делает сам — диктору не нужно «читать паузы».
    static let comma: SegmentID = "_pause.comma"
    /// Пауза на месте точки между двумя предложениями одной реплики.
    static let stop: SegmentID = "_pause.stop"

    var isPause: Bool { raw.hasPrefix("_pause.") }

    /// Имя годится для файла: [a-z0-9._], без пауз.
    var isValidFileName: Bool {
        !raw.isEmpty && !isPause && raw.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "_"
        }
    }
}

/// Реплика голоса.
nonisolated enum VoiceEvent: Hashable, Sendable {
    /// Камера впереди — главная фраза приложения.
    case camera(CameraCall)
    /// Одно название типа: ответ на уточнение отметки («Тренога»).
    case cameraName(Kind)
    /// Манёвр маршрута: «Через 300 метров — поверните направо. Из левого ряда»
    /// или, без полос, «…поверните налево. Перестройтесь в левый ряд».
    case maneuver(ManeuverCall)
    /// «Ограничение 40 через 200 м».
    case limitAhead(limit: Int, meters: Int)
    /// «Впереди пробка: около 1 км, плюс 4 мин». Метры уже округлены
    /// источником (до 100), секунды — целые.
    case jam(meters: Int, delaySeconds: Int)
    /// «Впереди пробка. Есть путь быстрее на 8 мин» — без улицы объезда.
    case detour(savingSeconds: Int)
    /// «Здесь часто ставят треногу[, обычно утром]».
    case hotspot(Peak?)
    /// Фраза без подстановок.
    case phrase(Phrase)

    // MARK: - Камера

    /// Тип камеры — ровно те, у которых есть записанное название.
    /// `CameraType.other` (название из реестра как есть) сюда не входит:
    /// произнести незнакомое слово может только синтезатор.
    enum Kind: String, CaseIterable, Hashable, Sendable {
        case stationaryCamera, stationaryRadar, intelligentRadar
        case mobileRadar, tripod, dpsPost, accident
    }

    /// Где камера относительно курса.
    enum Side: String, CaseIterable, Hashable, Sendable {
        case ahead, aheadLeft, aheadRight
    }

    struct CameraCall: Hashable, Sendable {
        enum Form: Hashable, Sendable {
            /// «Камеры впереди, 300 метров» — несколько камер вплотную.
            case group
            /// «Радар, 300 метров» — город, короткая фраза.
            case brief
            /// «По маршруту стационарный радар через 300 метров».
            case onRoute
            /// «Стационарный радар впереди справа, 300 метров» — трасса.
            case full(Side)
        }

        /// Хвост фразы: своя скорость и лимит.
        enum Tail: Hashable, Sendable {
            case none
            /// «, здесь 60».
            case limit(Int)
            /// «. Ваша скорость 75».
            case speed(Int)
            /// «. Ваша скорость 75, лимит 60».
            case speedAndLimit(speed: Int, limit: Int)
        }

        var kind: Kind
        var form: Form
        /// Расстояние так, как его округлил текст (50 м до 400, дальше 100 м).
        var meters: Int
        /// Неподтверждённая отметка водителей: «Отметка водителей: …».
        var fromDrivers = false
        var tail: Tail = .none
    }

    // MARK: - Манёвр

    enum Action: Hashable, Sendable {
        case turnLeft, turnRight, slightLeft, slightRight, sharpLeft, sharpRight
        case uturn, keepLeft, keepRight, merge, onRamp, offRamp
        /// Съезд с кольца по счёту, с первого.
        case roundabout(exit: Int)
        /// «вы прибыли» в ленте манёвров (не путать с фразой прибытия маршрута).
        case arrived

        /// Все действия без съездов кольца — для перечислений.
        static let simple: [Action] = [.turnLeft, .turnRight, .slightLeft, .slightRight,
                                       .sharpLeft, .sharpRight, .uturn, .keepLeft, .keepRight,
                                       .merge, .onRamp, .offRamp, .arrived]
    }

    /// Подсказка ряда словами (`LaneAdvice`).
    enum LaneRun: String, CaseIterable, Hashable, Sendable {
        case leftOne, leftTwo, leftThree, leftMany
        case rightOne, rightTwo, rightThree, rightMany
        case allButRight, allButLeft
        case middleOne, middleMany
    }

    /// С какого края проезжей части выполнять манёвр, когда полос от OSRM
    /// нет (`LaneAdvice.Edge`, этап 20.2): тип поворота плюс число полос
    /// нашей дороги из своей сети.
    enum LaneEdge: String, CaseIterable, Hashable, Sendable {
        /// Поворот налево: «Перестройтесь в левый ряд».
        case left
        /// Разворот: «Перестройтесь в крайний левый ряд».
        case farLeft
        /// Поворот направо: «Перестройтесь в правый ряд».
        case right
        /// Съезд, не называющий стороны: «Держитесь левее».
        case keepLeft
        /// «Держитесь правее».
        case keepRight
    }

    struct ManeuverCall: Hashable, Sendable {
        var action: Action
        /// nil — сама команда, у манёвра («поверните направо»).
        var meters: Int?
        /// Ряд — только в предупреждении заранее (у самого манёвра его не говорят).
        var lanes: LaneRun?
        /// Край без данных о полосах — там же и так же один раз, как `lanes`;
        /// вместе с `lanes` не бывает (полосы OSRM точнее догадки).
        var edge: LaneEdge? = nil
    }

    // MARK: - Треноги и фразы

    /// Когда на этом месте обычно ставят треногу.
    enum Peak: String, CaseIterable, Hashable, Sendable {
        case night, morning, day, evening
    }

    /// Фразы без подстановок. Ключ — та же русская строка каталога, что
    /// произносит код сегодня (`VoiceText` сверяет это).
    enum Phrase: String, CaseIterable, Hashable, Sendable {
        case overspeed, rerouted, arrived
        case roadClosure, roadClosureFromDrivers, roadwork
        case reportAccepted, reportConfirmed, reportAmended, reportDuplicate
        case reportNoPosition, reportNotDriving, reportQueuedOffline, reportQueuedServer
        case offline, tooOften, reportRefused, serverDown, reportsDisabled, badAnswer
        case thanks, reportRemoved, notSent, closure, roadworkShort
        case routeNoPosition, routeFailed, tripStarted, tripEnded, routeFinished
        /// «Камера, триста метров» — кнопка «Прослушать оповещение».
        case sample
    }
}
