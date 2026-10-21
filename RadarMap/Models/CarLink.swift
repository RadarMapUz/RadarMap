//
//  CarLink.swift
//  RadarMap
//
//  «Подключены к своей машине?» — CarPlay или выбранная магнитола по Bluetooth
//  (этап 26.2–26.3), и что из этого следует для поездки.
//
//  Режим «Только в машине» (владелец, 21.10: «пока не подключится к машине —
//  автостарт бесит») начинает поездку при подключении и заканчивает при
//  отключении. Признак машины — порт аудио-маршрута (`AVAudioSession`):
//  `.carAudio` (CarPlay) — всегда своя; Bluetooth — только выбранный в
//  настройках, по uid порта, а без совпадения uid — по имени (uid бывает
//  разным на разных версиях iOS).
//
//  Знакомые магнитолы из «Я за рулём» (`knownCarAudio`) — то же, но с одной
//  оговоркой: туда до 26.3 попадал ЛЮБОЙ Bluetooth-выход, в том числе
//  наушники. Нажал «Я за рулём» в AirPods — и с тех пор каждая поездка в
//  такси в тех же AirPods считалась «своей машиной» и писалась молча. Имена,
//  похожие на наушники, знакомой машиной больше не считаются и не
//  запоминаются; явный выбор в настройках — решение человека, его не судим.
//
//  Чистая логика — CarLinkTests.
//

import Foundation

/// Устройство машины, выбранное в настройках («Только в машине»).
struct CarAudioDevice: Codable, Hashable, Identifiable {
    /// `AVAudioSessionPortDescription.uid`.
    let uid: String
    /// `portName` — для показа и запасного совпадения.
    let name: String
    var id: String { uid }
}

nonisolated enum CarLink {

    enum PortKind: Equatable {
        case carPlay      // .carAudio
        case bluetooth    // .bluetoothA2DP / .bluetoothHFP / .bluetoothLE
        case other
    }

    /// Выход аудио-маршрута без AVFoundation — для тестов.
    struct Port: Equatable, Hashable {
        let uid: String
        let name: String
        let kind: PortKind
    }

    // MARK: - Признание машины

    /// Своя машина подключена: CarPlay — всегда, Bluetooth — выбранный.
    static func isLinked(ports: [Port], chosen: [CarAudioDevice]) -> Bool {
        ports.contains { port in
            switch port.kind {
            case .carPlay: return true
            case .bluetooth: return matches(port, chosen)
            case .other: return false
            }
        }
    }

    /// Своя машина для автостарта «Авто»/«Умный»: подключение выше или
    /// знакомая по «Я за рулём» магнитола (не наушники).
    static func isRecognized(ports: [Port], chosen: [CarAudioDevice], known: [String]) -> Bool {
        if isLinked(ports: ports, chosen: chosen) { return true }
        return ports.contains {
            $0.kind == .bluetooth && known.contains($0.name) && !looksLikeHeadphones($0.name)
        }
    }

    static func matches(_ port: Port, _ chosen: [CarAudioDevice]) -> Bool {
        chosen.contains { $0.uid == port.uid }
            || chosen.contains { $0.name == port.name && !port.name.isEmpty }
    }

    /// Что предложить в настройках: CarPlay и Bluetooth-выходы, подключённые
    /// сейчас, по одному на устройство (A2DP и HFP одной магнитолы — разные
    /// порты с одним именем).
    static func candidates(_ ports: [Port]) -> [Port] {
        var seen = Set<String>()
        return ports.filter { $0.kind != .other && seen.insert($0.name).inserted }
    }

    /// Bluetooth-имя похоже на наушники или колонку. Эвристика по имени —
    /// единственное, что даёт iOS: класса устройства в аудио-маршруте нет.
    /// Ошибка в сторону «наушники» стоит один вопрос «вы за рулём?»; в
    /// обратную — молча записанную чужую поездку.
    static func looksLikeHeadphones(_ name: String) -> Bool {
        let lower = name.lowercased()
        return headphoneMarkers.contains { lower.contains($0) }
    }

    private static let headphoneMarkers = [
        "airpods", "beats", "buds", "headphone", "headset", "earphone", "earbud",
        "наушник", "quietcomfort", "soundcore", "freebuds", "jabra", "wh-1000", "wf-1000",
        "powerbeats", "pixel buds", "nothing ear", "marshall", "jbl tune", "jbl live",
    ]

    // MARK: - Старт и стоп по подключению

    struct State: Equatable {
        let mode: TripStartMode
        let linked: Bool
        let wasLinked: Bool
        let tripActive: Bool
        /// Идущая поездка началась (или застала) подключение к машине.
        let tripFromLink: Bool
        /// «Я пассажир» на эту езду.
        let passenger: Bool
        /// CoreMotion сейчас видит езду (только «Авто»/«Умный»).
        let motionDriving: Bool
    }

    enum Action: Equatable {
        case none
        /// Начать поездку.
        case start
        /// Поездка уже идёт — пометить как «от машины», отменить ожидающий стоп.
        case adopt
        /// Отключились — закончить поездку после паузы (`carLinkStopGraceSeconds`):
        /// BT отваливается на перезапуске мотора, а заправку склеит TripMerge.
        case scheduleStop
    }

    static func onChange(_ s: State) -> Action {
        if s.linked, !s.wasLinked {
            if s.tripActive { return .adopt }
            if s.passenger { return .none }
            switch s.mode {
            case .carOnly: return .start
            // CoreMotion уже видит езду, а машина подключилась позже (CarPlay
            // по воздуху — через 20–30 с после мотора): в «Умном» автостарт к
            // этому моменту спросил «вы за рулём?» и не начал — теперь ясно.
            case .smart, .auto: return s.motionDriving ? .start : .none
            case .manual: return .none
            }
        }
        if !s.linked, s.wasLinked, s.tripActive, s.tripFromLink, s.mode == .carOnly {
            return .scheduleStop
        }
        return .none
    }

    // MARK: - Автостарт по CoreMotion («Авто»/«Умный»)

    enum AutoStart: Equatable {
        /// Начать и не спрашивать (своя машина).
        case start
        /// Начать и спросить «вы за рулём?» («Авто», машина незнакомая).
        case startAndAsk
        /// Не начинать, спросить («Умный»; «Авто», когда своя машина известна).
        case askOnly
        /// Не начинать и не спрашивать.
        case ignore
    }

    /// Решение по старту от CoreMotion. `ownCarConfigured` — человек сам
    /// выбрал устройство машины: тогда её отсутствие — доказательство
    /// «не своя», и даже «Авто» не пишет поездку молча, а спрашивает (такси).
    static func autoStart(mode: TripStartMode, recognized: Bool, passenger: Bool,
                          ownCarConfigured: Bool) -> AutoStart {
        if passenger { return .ignore }
        switch mode {
        case .manual, .carOnly: return .ignore
        case .smart: return recognized ? .start : .askOnly
        case .auto:
            if recognized { return .start }
            return ownCarConfigured ? .askOnly : .startAndAsk
        }
    }

    // MARK: - Предложение «Только в машине» (миграция)

    /// Один раз — тем, у кого CarPlay уже подключался, режим другой, и на
    /// предложение ещё не отвечали. Молча режим не меняем.
    static func shouldOffer(carPlaySeen: Bool, mode: TripStartMode, answered: Bool) -> Bool {
        carPlaySeen && !answered && mode != .carOnly
    }
}
