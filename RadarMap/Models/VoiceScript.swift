//
//  VoiceScript.swift
//  RadarMap
//
//  Сценарий диктора (этап 16.1–16.2): какие отрывки записать и что в них
//  сказать.
//
//  Список отрывков не пишется руками — он ВЫВОДИТСЯ: перебираем всё, что
//  приложение может сказать (`eventSpace`, границы — те же, что у кода,
//  который говорит), собираем каждое событие `VoiceComposer`-ом и берём
//  объединение. Поэтому в сценарии нет ни одного отрывка, который никогда не
//  прозвучит, и нет фразы, для которой отрывка не хватит, — оба утверждения
//  проверяет VoiceComposerTests.
//
//  Тексты узбекских отрывков совпадают с переводом в каталоге строк: диктор
//  произносит ровно то, что приложение пишет на экране и что сегодня читает
//  синтезатор (VoiceComposerTests сверяет с docs/voice_phrases_uz.md).
//
//  Самодостаточен (Foundation): `tools/voice_kit/export_script.sh` собирает
//  этот файл вместе с VoiceEvent и VoiceComposer и печатает script_uz.csv.
//

import Foundation

nonisolated enum VoiceScript {

    /// Наибольшее число, которое говорится записью: скорость и лимит.
    static let maxNumber = 299
    /// Наибольший съезд кольца, у которого есть запись.
    static let maxRoundaboutExit = 8

    /// Границы того, что приложение говорит. Сверяются с AppConfig в тестах:
    /// вырастет радиус камеры или окно пробки — тест покажет, каких ступеней
    /// не хватит, раньше водителя.
    enum Bounds {
        /// Камера: `AppConfig.maxDynamicRadius`.
        static let cameraMaxMeters = 1500
        /// Манёвр: `AppConfig.maneuverFarCallMeters`, округление до 100.
        static let maneuverMaxMeters = 900
        /// Лимит впереди: `AppConfig.limitAheadMinMeters…limitAheadMaxMeters`.
        static let limitAheadMeters = 100...400
        /// Пробка: от `jamMinLengthMeters` до `jamLookAheadMeters`.
        static let jamMeters = 300...1500
        /// Скорость в хвосте фразы: от `speakSpeedThresholdKmh`.
        static let speedKmh = 20...maxNumber
        /// Лимиты дорог.
        static let limitKmh = 5...150
        /// Задержка пробки и выигрыш объезда: от минуты до двух часов.
        static let delaySeconds = 60...7200
    }

    // MARK: - Что приложение может сказать

    /// Представительное множество событий: каждое измерение (тип, сторона,
    /// расстояние, число, длительность, манёвр, ряд) перебрано целиком при
    /// остальных постоянных — объединение отрывков то же, что у полного
    /// произведения, а событий — тысячи, а не миллионы. Порядок важен:
    /// первое событие с отрывком даёт ему фразу-пример в сценарии, поэтому
    /// типичное идёт раньше редкого.
    static let eventSpace: [VoiceEvent] = {
        var events: [VoiceEvent] = []
        typealias Call = VoiceEvent.CameraCall
        // Камера: самое частое — короткая городская фраза.
        for kind in VoiceEvent.Kind.allCases {
            events.append(.camera(Call(kind: kind, form: .brief, meters: 300)))
        }
        for kind in VoiceEvent.Kind.allCases {
            for side in VoiceEvent.Side.allCases {
                events.append(.camera(Call(kind: kind, form: .full(side), meters: 500)))
            }
            events.append(.camera(Call(kind: kind, form: .onRoute, meters: 400)))
        }
        events.append(.camera(Call(kind: .stationaryCamera, form: .group, meters: 300)))
        events.append(.camera(Call(kind: .mobileRadar, form: .full(.ahead), meters: 300,
                                   fromDrivers: true)))
        // Расстояния — так, как их округляет фраза о камере.
        for meters in cameraDistances {
            events.append(.camera(Call(kind: .stationaryRadar, form: .brief, meters: meters)))
            events.append(.camera(Call(kind: .stationaryRadar, form: .onRoute, meters: meters)))
        }
        // Хвосты: скорость и лимит.
        events.append(.camera(Call(kind: .stationaryRadar, form: .full(.ahead), meters: 400,
                                   tail: .speedAndLimit(speed: 75, limit: 60))))
        events.append(.camera(Call(kind: .stationaryRadar, form: .full(.ahead), meters: 400,
                                   tail: .limit(70))))
        for speed in Bounds.speedKmh {
            events.append(.camera(Call(kind: .mobileRadar, form: .full(.ahead), meters: 300,
                                       tail: .speed(speed))))
        }
        for limit in Bounds.limitKmh {
            events.append(.camera(Call(kind: .stationaryRadar, form: .brief, meters: 300,
                                       tail: .limit(limit))))
        }
        // Манёвры: сама команда, предупреждение заранее, ряд.
        let actions = VoiceEvent.Action.simple
            + (1...maxRoundaboutExit).map { VoiceEvent.Action.roundabout(exit: $0) }
        for action in actions {
            events.append(.maneuver(.init(action: action, meters: nil, lanes: nil)))
        }
        for meters in maneuverDistances {
            events.append(.maneuver(.init(action: .turnRight, meters: meters, lanes: nil)))
        }
        for action in actions {
            events.append(.maneuver(.init(action: action, meters: 300, lanes: nil)))
        }
        for run in VoiceEvent.LaneRun.allCases {
            events.append(.maneuver(.init(action: .turnLeft, meters: 300, lanes: run)))
        }
        // Край без полос (20.2): по команде, у которой он бывает.
        let edgeActions: [VoiceEvent.LaneEdge: VoiceEvent.Action] = [
            .left: .turnLeft, .farLeft: .uturn, .right: .turnRight,
            .keepLeft: .offRamp, .keepRight: .offRamp]
        for edge in VoiceEvent.LaneEdge.allCases {
            events.append(.maneuver(.init(action: edgeActions[edge] ?? .turnLeft, meters: 300,
                                          lanes: nil, edge: edge)))
        }
        // Лимит впереди.
        for meters in stride(from: Bounds.limitAheadMeters.lowerBound,
                             through: Bounds.limitAheadMeters.upperBound, by: 50) {
            events.append(.limitAhead(limit: 40, meters: meters))
        }
        for limit in Bounds.limitKmh {
            events.append(.limitAhead(limit: limit, meters: 200))
        }
        // Пробка и объезд.
        for meters in stride(from: Bounds.jamMeters.lowerBound, through: Bounds.jamMeters.upperBound, by: 100) {
            events.append(.jam(meters: meters, delaySeconds: 240))
        }
        for seconds in stride(from: Bounds.delaySeconds.lowerBound, through: Bounds.delaySeconds.upperBound,
                              by: 60) {
            events.append(.jam(meters: 1000, delaySeconds: seconds))
            events.append(.detour(savingSeconds: seconds))
        }
        // Треноги, названия типов, фразы.
        events.append(.hotspot(nil))
        for peak in VoiceEvent.Peak.allCases { events.append(.hotspot(peak)) }
        for kind in VoiceEvent.Kind.allCases { events.append(.cameraName(kind)) }
        for phrase in VoiceEvent.Phrase.allCases { events.append(.phrase(phrase)) }
        return events
    }()

    /// Как фраза о камере округляет: 50 м до 400, дальше 100 м.
    static var cameraDistances: [Int] {
        Array(stride(from: 50, to: 400, by: 50)) + Array(stride(from: 400, through: Bounds.cameraMaxMeters, by: 100))
    }

    /// Манёвр: ближнее предупреждение — до 50 м, дальнее — до 100 м.
    static var maneuverDistances: [Int] {
        Array(stride(from: 50, through: 300, by: 50))
            + Array(stride(from: 400, through: Bounds.maneuverMaxMeters, by: 100))
    }

    // MARK: - Сценарий

    struct Line: Equatable, Sendable {
        let id: SegmentID
        let text: String
        /// Фраза, в которой отрывок звучит, — для интонации.
        let example: String
        /// Где в фразе: начало / середина / конец.
        let position: String
        let note: String
    }

    /// Все отрывки языка в порядке сценария: по группам, числа — по величине.
    static func inventory(_ language: VoiceLanguage) -> [SegmentID] {
        var seen = Set<SegmentID>()
        for event in eventSpace {
            for id in VoiceComposer.segments(for: event, in: language) ?? [] where !id.isPause {
                seen.insert(id)
            }
        }
        return seen.sorted(by: scriptOrder)
    }

    /// Порядок чтения у диктора: связные группы (типы, стороны, слова фраз,
    /// числа, расстояния, манёвры…), внутри группы числа — по величине
    /// («dist.50» раньше «dist.100», «dist.300» раньше «dist.300.after»).
    static func scriptOrder(_ a: SegmentID, _ b: SegmentID) -> Bool {
        let groups = ["kind", "side", "w", "num", "unit", "dist", "man", "lane", "peak", "p"]
        let left = a.raw.split(separator: "."), right = b.raw.split(separator: ".")
        let rank = { (parts: [Substring]) in groups.firstIndex(of: String(parts.first ?? "")) ?? groups.count }
        if rank(left) != rank(right) { return rank(left) < rank(right) }
        for (x, y) in zip(left, right) where x != y {
            if let i = Int(x), let j = Int(y) { return i < j }
            return x < y
        }
        return left.count < right.count
    }

    /// Сценарий: отрывок, текст, пример, место в фразе, заметка диктору.
    static func lines(_ language: VoiceLanguage) -> [Line] {
        var example: [SegmentID: String] = [:]
        var positions: [SegmentID: Set<Int>] = [:]
        for event in eventSpace {
            guard let ids = VoiceComposer.segments(for: event, in: language) else { continue }
            let spoken = ids.filter { !$0.isPause }
            for (index, id) in spoken.enumerated() {
                if example[id] == nil { example[id] = text(of: ids, language: language) }
                let place = spoken.count == 1 ? 3 : index == 0 ? 0 : index == spoken.count - 1 ? 2 : 1
                positions[id, default: []].insert(place)
            }
        }
        return inventory(language).map { id in
            Line(id: id, text: text(id, language) ?? "",
                 example: example[id] ?? "",
                 position: positionTitle(positions[id] ?? []),
                 note: note(id, language))
        }
    }

    private static func positionTitle(_ places: Set<Int>) -> String {
        if places == [3] { return "отдельно" }
        let names = [(0, "начало"), (1, "середина"), (2, "конец"), (3, "отдельно")]
        return names.filter { places.contains($0.0) }.map(\.1).joined(separator: ", ")
    }

    /// Текст фразы из отрывков — так, как она прозвучит: паузы становятся
    /// знаками препинания. nil — какого-то отрывка нет в сценарии.
    static func text(of ids: [SegmentID], language: VoiceLanguage) -> String? {
        var out = ""
        var capitalizeNext = true
        for id in ids {
            if id == .comma { out += ","; continue }
            if id == .stop { out += "."; capitalizeNext = true; continue }
            guard let word = text(id, language) else { return nil }
            if !out.isEmpty { out += " " }
            out += capitalizeNext ? word.prefix(1).uppercased() + word.dropFirst() : midSentence(word)
            capitalizeNext = false
        }
        return out
    }

    /// Слово внутри предложения — со строчной, кроме аббревиатур («YPX»,
    /// «ДТП»): «Marshrutda koʻchma radar», но «пост ДПС».
    private static func midSentence(_ word: String) -> String {
        let letters = Array(word.prefix(2))
        guard letters.count == 2, letters[1].isLowercase else { return word }
        return word.prefix(1).lowercased() + word.dropFirst()
    }

    // MARK: - Тексты отрывков

    static func text(_ id: SegmentID, _ language: VoiceLanguage) -> String? {
        switch language {
        case .uz: return uzbek[id]
        case .ru: return russian[id]
        }
    }

    /// Заметка диктору там, где запись расходится с написанным.
    static func note(_ id: SegmentID, _ language: VoiceLanguage) -> String {
        guard language == .uz else { return "" }
        switch id.raw {
        case "kind.dps_post": return "аббревиатуру читать так, как говорят вслух (уточнить: «ye-pe-xa posti»)"
        case "kind.accident": return "аббревиатуру читать так, как говорят вслух (уточнить: «ye-te-xa»)"
        case "w.drivers_mark": return "после — пауза двоеточия, фраза продолжается"
        case "num.100": return "«yuz» без «bir»: 120 — «yuz yigirma» (так говорит и синтезатор)"
        default:
            if id.raw.hasPrefix("num.") {
                return "числительное: ровный тон — запись встаёт и в середину фразы, и в конец"
            }
            return ""
        }
    }

    // MARK: Узбекский

    private static let uzUnits = [1: "bir", 2: "ikki", 3: "uch", 4: "toʻrt", 5: "besh",
                                  6: "olti", 7: "yetti", 8: "sakkiz", 9: "toʻqqiz"]
    private static let uzTens = [10: "oʻn", 20: "yigirma", 30: "oʻttiz", 40: "qirq", 50: "ellik",
                                 60: "oltmish", 70: "yetmish", 80: "sakson", 90: "toʻqson"]

    /// Число словами по-узбекски до 999 («yuz», не «bir yuz» — как UzbekSpeech).
    static func uzbekNumber(_ value: Int) -> String {
        var parts: [String] = []
        var rest = value
        if rest >= 100 {
            let hundreds = rest / 100
            parts.append(hundreds == 1 ? "yuz" : "\(uzUnits[hundreds] ?? "") yuz")
            rest %= 100
        }
        if rest >= 10 {
            parts.append(uzTens[rest / 10 * 10] ?? "")
            rest %= 10
        }
        if rest > 0 { parts.append(uzUnits[rest] ?? "") }
        return parts.joined(separator: " ")
    }

    private static func uzbekDistance(_ meters: Int) -> String {
        switch meters {
        case 1000: return "bir kilometr"
        case 1500: return "bir yarim kilometr"
        default:   return uzbekNumber(meters) + " metr"
        }
    }

    static let uzbek: [SegmentID: String] = {
        var t: [SegmentID: String] = [
            // Стационарные типы по-узбекски голос называет одним словом —
            // «Kamera» / «Radar» (VoiceComposer.Uzbek.kind, решение 23.10).
            "kind.mobile_radar": "Koʻchma radar",
            "kind.tripod": "Uch oyoq kamera",
            "kind.dps_post": "YPX posti",
            "kind.accident": "YTH",
            "kind.camera": "Kamera",
            "kind.radar": "Radar",
            "side.ahead": "oldinda",
            "side.ahead_left": "oldinda chapda",
            "side.ahead_right": "oldinda oʻngda",
            "w.cameras_ahead": "Oldinda kameralar",
            "w.on_route": "Marshrutda",
            "w.drivers_mark": "Haydovchilar belgisi",
            "w.your_speed": "Tezligingiz",
            "w.limit": "cheklov",
            "w.here": "bu yerda",
            "w.speed_limit": "tezlik cheklovi",
            "w.jam_ahead": "Oldinda tirbandlik",
            "w.about": "taxminan",
            "w.plus": "qoʻshimcha",
            "w.faster_way": "tezroq yoʻl bor",
            "w.send_later": "keyinroq yuboraman",
            "w.not_sent": "Yuborilmadi",
            "unit.minute": "daqiqa",
            "unit.hour": "soat",
            "man.turn_left": "chapga buriling",
            "man.turn_right": "oʻngga buriling",
            "man.slight_left": "biroz chapga oling",
            "man.slight_right": "biroz oʻngga oling",
            "man.sharp_left": "keskin chapga buriling",
            "man.sharp_right": "keskin oʻngga buriling",
            "man.uturn": "orqaga buriling",
            "man.keep_left": "chap tomonda yuring",
            "man.keep_right": "oʻng tomonda yuring",
            "man.merge": "oqimga qoʻshiling",
            "man.on_ramp": "yoʻl ayirmasiga chiqing",
            "man.off_ramp": "chiqish yoʻliga buriling",
            "man.arrived": "yetib keldingiz",
            "man.roundabout": "aylanada",
            "lane.left_one": "Chap qatordan",
            "lane.left_two": "Chapdagi ikki qatordan",
            "lane.left_three": "Chapdagi uch qatordan",
            "lane.left_many": "Chap qatorlardan",
            "lane.right_one": "Oʻng qatordan",
            "lane.right_two": "Oʻngdagi ikki qatordan",
            "lane.right_three": "Oʻngdagi uch qatordan",
            "lane.right_many": "Oʻng qatorlardan",
            "lane.all_but_right": "Oʻngdan boshqa istalgan qatordan",
            "lane.all_but_left": "Chapdan boshqa istalgan qatordan",
            "lane.middle_one": "Oʻrta qatordan",
            "lane.middle_many": "Oʻrta qatorlardan",
            "lane.edge_left": "Chap qatorga oʻting",
            "lane.edge_far_left": "Eng chap qatorga oʻting",
            "lane.edge_right": "Oʻng qatorga oʻting",
            "peak.night": "odatda kechasi",
            "peak.morning": "odatda ertalab",
            "peak.day": "odatda kunduzi",
            "peak.evening": "odatda kechqurun",
            "p.overspeed": "Tezlik oshirildi",
            "p.rerouted": "Marshrut qayta qurildi",
            "p.arrived": "Siz yetib keldingiz",
            "p.road_closure": "Oldinda yoʻl yopiq",
            "p.roadwork": "Oldinda yoʻl taʼmirlanmoqda",
            "p.tripod_often": "Bu yerda tez-tez uchoyoq qoʻyiladi",
            "p.report_accepted": "Qabul qilindi, rahmat",
            "p.report_confirmed": "Tasdiqlandi, rahmat",
            "p.report_amended": "Turi aniqlashtirildi",
            "p.report_duplicate": "Bu yerda allaqachon belgilangan",
            "p.report_no_position": "Sunʼiy yoʻldoshlarni kutmoqdamiz",
            "p.report_not_driving": "Belgi harakat paytida qoʻyiladi",
            "p.offline": "Aloqa yoʻq",
            "p.too_often": "Juda tez-tez, bir daqiqa kuting",
            "p.report_refused": "Server belgini rad etdi",
            "p.server_down": "Server javob bermayapti",
            "p.reports_disabled": "Belgilar hozir oʻchirilgan",
            "p.bad_answer": "Serverdan gʻalati javob",
            "p.thanks": "Rahmat!",
            "p.report_removed": "Belgi olib tashlandi",
            "p.closure": "Yopiq",
            "p.roadwork_short": "Taʼmir",
            "p.route_no_position": "Aniq joylashuv yoʻq — hozircha yoʻnalish tuzib boʻlmaydi",
            "p.route_failed": "Yoʻnalish tuzilmadi",
            "p.trip_started": "Safar boshlandi — kameralarni kuzatyapman",
            "p.trip_ended": "Safar yakunlandi",
            "p.route_finished": "Marshrut yakunlandi",
        ]
        for (value, word) in uzUnits { t[SegmentID("num.\(value)")] = word }
        for (value, word) in uzTens { t[SegmentID("num.\(value)")] = word }
        t["num.100"] = "yuz"
        t["num.200"] = "ikki yuz"
        let ordinals = [1: "birinchi", 2: "ikkinchi", 3: "uchinchi", 4: "toʻrtinchi",
                        5: "beshinchi", 6: "oltinchi", 7: "yettinchi", 8: "sakkizinchi"]
        for (exit, word) in ordinals { t[SegmentID("man.exit.\(exit)")] = "\(word) chiqish" }
        for step in VoiceDistance.steps {
            t[SegmentID("dist.\(step)")] = uzbekDistance(step)
            t[SegmentID("dist.\(step).after")] = uzbekDistance(step) + "dan soʻng"
        }
        return t
    }()

    // MARK: Русский

    private static let ruUnits = [1: "один", 2: "два", 3: "три", 4: "четыре", 5: "пять",
                                  6: "шесть", 7: "семь", 8: "восемь", 9: "девять"]
    private static let ruTeens = [10: "десять", 11: "одиннадцать", 12: "двенадцать", 13: "тринадцать",
                                  14: "четырнадцать", 15: "пятнадцать", 16: "шестнадцать",
                                  17: "семнадцать", 18: "восемнадцать", 19: "девятнадцать"]
    private static let ruTens = [20: "двадцать", 30: "тридцать", 40: "сорок", 50: "пятьдесят",
                                 60: "шестьдесят", 70: "семьдесят", 80: "восемьдесят", 90: "девяносто"]

    /// Расстояние по-русски: (именительный, «около» + родительный).
    private static let ruDistances: [Int: (String, String)] = [
        50: ("пятьдесят метров", "около пятидесяти метров"),
        100: ("сто метров", "около ста метров"),
        150: ("сто пятьдесят метров", "около ста пятидесяти метров"),
        200: ("двести метров", "около двухсот метров"),
        250: ("двести пятьдесят метров", "около двухсот пятидесяти метров"),
        300: ("триста метров", "около трёхсот метров"),
        350: ("триста пятьдесят метров", "около трёхсот пятидесяти метров"),
        400: ("четыреста метров", "около четырёхсот метров"),
        500: ("пятьсот метров", "около пятисот метров"),
        600: ("шестьсот метров", "около шестисот метров"),
        700: ("семьсот метров", "около семисот метров"),
        800: ("восемьсот метров", "около восьмисот метров"),
        900: ("девятьсот метров", "около девятисот метров"),
        1000: ("один километр", "около километра"),
        1500: ("полтора километра", "около полутора километров"),
    ]

    static let russian: [SegmentID: String] = {
        var t: [SegmentID: String] = [
            "kind.stationary_camera": "Стационарная камера",
            "kind.stationary_radar": "Стационарный радар",
            "kind.intelligent_radar": "Интеллектуальная камера + радар",
            "kind.mobile_radar": "Передвижной радар",
            "kind.tripod": "Тренога",
            "kind.dps_post": "Пост ДПС",
            "kind.accident": "ДТП",
            "kind.camera": "Камера",
            "kind.radar": "Радар",
            "side.ahead": "впереди",
            "side.ahead_left": "впереди слева",
            "side.ahead_right": "впереди справа",
            "w.cameras_ahead": "Камеры впереди",
            "w.on_route": "По маршруту",
            "w.drivers_mark": "Отметка водителей",
            "w.your_speed": "Ваша скорость",
            "w.limit": "лимит",
            "w.here": "здесь",
            "w.speed_limit": "Ограничение",
            "w.jam_ahead": "Впереди пробка",
            "w.plus": "плюс",
            "w.faster_way": "Есть путь быстрее на",
            "w.send_later": "отправлю позже",
            "w.not_sent": "Не отправилось",
            "unit.minute.one": "минута",
            "unit.minute.one.acc": "минуту",
            "unit.minute.few": "минуты",
            "unit.minute.many": "минут",
            "unit.hour.one": "час",
            "unit.hour.few": "часа",
            "unit.hour.many": "часов",
            "num.1.f": "одна",
            "num.1.f.acc": "одну",
            "num.2.f": "две",
            "num.100": "сто",
            "num.200": "двести",
            "man.turn_left": "поверните налево",
            "man.turn_right": "поверните направо",
            "man.slight_left": "плавно левее",
            "man.slight_right": "плавно правее",
            "man.sharp_left": "круто налево",
            "man.sharp_right": "круто направо",
            "man.uturn": "разворот",
            "man.keep_left": "держитесь левее",
            "man.keep_right": "держитесь правее",
            "man.merge": "перестройтесь в поток",
            "man.on_ramp": "съезд на развязку",
            "man.off_ramp": "сверните на съезд",
            "man.arrived": "вы прибыли",
            "man.roundabout": "на кольце",
            "lane.left_one": "Из левого ряда",
            "lane.left_two": "Из двух левых рядов",
            "lane.left_three": "Из трёх левых рядов",
            "lane.left_many": "Из левых рядов",
            "lane.right_one": "Из правого ряда",
            "lane.right_two": "Из двух правых рядов",
            "lane.right_three": "Из трёх правых рядов",
            "lane.right_many": "Из правых рядов",
            "lane.all_but_right": "Из любого ряда, кроме правого",
            "lane.all_but_left": "Из любого ряда, кроме левого",
            "lane.middle_one": "Из среднего ряда",
            "lane.middle_many": "Из средних рядов",
            "lane.edge_left": "Перестройтесь в левый ряд",
            "lane.edge_far_left": "Перестройтесь в крайний левый ряд",
            "lane.edge_right": "Перестройтесь в правый ряд",
            "peak.night": "обычно ночью",
            "peak.morning": "обычно утром",
            "peak.day": "обычно днём",
            "peak.evening": "обычно вечером",
            "p.overspeed": "Превышение скорости",
            "p.rerouted": "Маршрут перестроен",
            "p.arrived": "Вы прибыли",
            "p.road_closure": "Впереди перекрытие дороги",
            "p.road_closure_mark": "впереди перекрытие",
            "p.roadwork": "Впереди ремонт дороги",
            "p.tripod_often": "Здесь часто ставят треногу",
            "p.report_accepted": "Принято, спасибо",
            "p.report_confirmed": "Подтвердили, спасибо",
            "p.report_amended": "Тип уточнён",
            "p.report_duplicate": "Уже отметили здесь",
            "p.report_no_position": "Ждём спутники",
            "p.report_not_driving": "Отметка ставится в движении",
            "p.offline": "Нет связи",
            "p.too_often": "Слишком часто, подождите минуту",
            "p.report_refused": "Сервер отклонил отметку",
            "p.server_down": "Сервер не отвечает",
            "p.reports_disabled": "Отметки сейчас выключены",
            "p.bad_answer": "Странный ответ сервера",
            "p.thanks": "Спасибо!",
            "p.report_removed": "Отметка убрана",
            "p.closure": "Перекрыто",
            "p.roadwork_short": "Ремонт",
            "p.route_no_position": "Не вижу точного положения — маршрут пока не построить",
            "p.route_failed": "Маршрут не построился",
            "p.trip_started": "Поездка началась — слежу за камерами",
            "p.trip_ended": "Поездка завершена",
            "p.route_finished": "Маршрут завершён",
        ]
        for (value, word) in ruUnits { t[SegmentID("num.\(value)")] = word }
        for (value, word) in ruTeens { t[SegmentID("num.\(value)")] = word }
        for (value, word) in ruTens { t[SegmentID("num.\(value)")] = word }
        let ordinals = [1: "первый", 2: "второй", 3: "третий", 4: "четвёртый",
                        5: "пятый", 6: "шестой", 7: "седьмой", 8: "восьмой"]
        for (exit, word) in ordinals { t[SegmentID("man.exit.\(exit)")] = "\(word) съезд" }
        for (step, forms) in ruDistances {
            t[SegmentID("dist.\(step)")] = forms.0
            t[SegmentID("dist.\(step).after")] = "через " + forms.0
            t[SegmentID("dist.\(step).about")] = forms.1
        }
        return t
    }()

    // MARK: - CSV для диктора

    /// script_<язык>.csv: id, текст, пример, место в фразе, заметка.
    static func csv(_ language: VoiceLanguage) -> String {
        var rows = ["id,text,example,position,note"]
        for line in lines(language) {
            rows.append([line.id.raw, line.text, line.example, line.position, line.note]
                .map(csvField).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
