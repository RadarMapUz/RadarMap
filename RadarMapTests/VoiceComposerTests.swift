//
//  VoiceComposerTests.swift
//  RadarMapTests
//
//  Записанный голос, этап 16.1: событие → отрывки. Главное — покрытие:
//  каждая фраза, которую приложение говорит, собирается из записанных
//  отрывков целиком, и каждая из 104 фраз docs/voice_phrases_uz.md либо
//  собирается, либо названо, почему её записью не говорят.
//

import XCTest
@testable import RadarMap

final class VoiceComposerTests: XCTestCase {

    private typealias Call = VoiceEvent.CameraCall

    private func uz(_ event: VoiceEvent) -> String? {
        VoiceComposer.segments(for: event, in: .uz).flatMap { VoiceScript.text(of: $0, language: .uz) }
    }

    private func ru(_ event: VoiceEvent) -> String? {
        VoiceComposer.segments(for: event, in: .ru).flatMap { VoiceScript.text(of: $0, language: .ru) }
    }

    // MARK: - Числа

    func testUzbekNumbersComposeFromTensAndUnits() {
        XCTAssertEqual(VoiceComposer.Uzbek.number(65), ["num.60", "num.5"])
        XCTAssertEqual(VoiceScript.text(of: VoiceComposer.Uzbek.number(65)!, language: .uz), "Oltmish besh")
        XCTAssertEqual(VoiceComposer.Uzbek.number(40), ["num.40"])
        XCTAssertEqual(VoiceComposer.Uzbek.number(7), ["num.7"])
        XCTAssertEqual(VoiceComposer.Uzbek.number(120), ["num.100", "num.20"], "120 — «yuz yigirma», без «bir»")
        XCTAssertEqual(VoiceComposer.Uzbek.number(299), ["num.200", "num.90", "num.9"])
        XCTAssertNil(VoiceComposer.Uzbek.number(0), "ноль не говорится")
        XCTAssertNil(VoiceComposer.Uzbek.number(300), "скорость за 299 — синтезатором")
    }

    /// Те же числа, что читает синтезатор (UzbekSpeech.numeral): запись и
    /// синтезатор не должны называть одно число по-разному.
    func testUzbekNumbersAgreeWithSynthesizerSpelling() {
        for value in 1...VoiceScript.maxNumber {
            let ids = VoiceComposer.Uzbek.number(value)!
            let words = ids.compactMap { VoiceScript.text($0, .uz) }.joined(separator: " ")
            XCTAssertEqual(Self.normalized(words), Self.normalized(UzbekSpeech.numeral(value)), "\(value)")
        }
    }

    func testRussianNumbersKeepTeensAndFeminineForms() {
        XCTAssertEqual(VoiceComposer.Russian.number(11), ["num.11"])
        XCTAssertEqual(VoiceComposer.Russian.number(115), ["num.100", "num.15"])
        XCTAssertEqual(VoiceComposer.Russian.number(65), ["num.60", "num.5"])
        XCTAssertEqual(VoiceComposer.Russian.number(21, gender: .feminine), ["num.20", "num.1.f"])
        XCTAssertEqual(VoiceComposer.Russian.number(21, gender: .feminine, accusative: true), ["num.20", "num.1.f.acc"])
        XCTAssertEqual(VoiceComposer.Russian.number(2, gender: .feminine), ["num.2.f"])
        XCTAssertEqual(VoiceComposer.Russian.number(12, gender: .feminine), ["num.12"])
        XCTAssertEqual(VoiceComposer.Russian.plural(1), .one)
        XCTAssertEqual(VoiceComposer.Russian.plural(11), .many)
        XCTAssertEqual(VoiceComposer.Russian.plural(22), .few)
        XCTAssertEqual(VoiceComposer.Russian.plural(14), .many)
    }

    // MARK: - Расстояния

    func testDistanceRoundsToRecordedSteps() {
        XCTAssertEqual(VoiceDistance.step(for: 50), 50)
        XCTAssertEqual(VoiceDistance.step(for: 300), 300)
        XCTAssertEqual(VoiceDistance.step(for: 900), 900)
        XCTAssertEqual(VoiceDistance.step(for: 1100), 1000)
        XCTAssertEqual(VoiceDistance.step(for: 1200), 1000)
        XCTAssertEqual(VoiceDistance.step(for: 1300), 1500, "1,3 км звучит как полтора")
        XCTAssertEqual(VoiceDistance.step(for: 1500), 1500)
        XCTAssertNil(VoiceDistance.step(for: 0), "«0 метров» — синтезатором")
        XCTAssertNil(VoiceDistance.step(for: 20), "до ближайшей ступени больше 25 %")
        XCTAssertNil(VoiceDistance.step(for: 3000))
    }

    /// Каждое расстояние, которое фраза о камере может назвать, есть в записи.
    func testEveryCameraDistanceHasAStep() {
        for meters in VoiceScript.cameraDistances {
            XCTAssertNotNil(VoiceDistance.step(for: meters), "\(meters) м")
        }
    }

    /// Границы сценария не уже того, что говорит код. Вырос радиус камеры
    /// или окно пробки — этот тест скажет, каких ступеней не хватит.
    func testScriptBoundsCoverAppConfig() {
        XCTAssertGreaterThanOrEqual(VoiceScript.Bounds.cameraMaxMeters, Int(AppConfig.maxDynamicRadius))
        XCTAssertGreaterThanOrEqual(VoiceScript.Bounds.maneuverMaxMeters,
                                    Int((AppConfig.maneuverFarCallMeters / 100).rounded() * 100))
        XCTAssertLessThanOrEqual(VoiceScript.Bounds.limitAheadMeters.lowerBound, Int(AppConfig.limitAheadMinMeters))
        XCTAssertGreaterThanOrEqual(VoiceScript.Bounds.limitAheadMeters.upperBound, Int(AppConfig.limitAheadMaxMeters))
        XCTAssertLessThanOrEqual(VoiceScript.Bounds.jamMeters.lowerBound, Int(AppConfig.jamMinLengthMeters))
        XCTAssertGreaterThanOrEqual(VoiceScript.Bounds.jamMeters.upperBound, Int(AppConfig.jamLookAheadMeters))
        XCTAssertLessThanOrEqual(VoiceScript.Bounds.speedKmh.lowerBound, Int(AppConfig.speakSpeedThresholdKmh))
        XCTAssertLessThanOrEqual(VoiceScript.Bounds.delaySeconds.lowerBound, Int(AppConfig.jamMinDelaySeconds))
        XCTAssertLessThanOrEqual(VoiceScript.Bounds.delaySeconds.lowerBound, Int(AppConfig.detourMinSavingSeconds))
        XCTAssertLessThanOrEqual(VoiceScript.Bounds.maneuverMaxMeters, VoiceDistance.steps.max()!)
    }

    // MARK: - Фразы

    func testCameraPhrasesInUzbek() {
        XCTAssertEqual(uz(.camera(Call(kind: .stationaryCamera, form: .brief, meters: 300))),
                       "Kamera, uch yuz metr")
        XCTAssertEqual(uz(.camera(Call(kind: .stationaryRadar, form: .full(.aheadRight), meters: 500))),
                       "Statsionar radar oldinda oʻngda, besh yuz metr")
        XCTAssertEqual(uz(.camera(Call(kind: .stationaryRadar, form: .onRoute, meters: 500))),
                       "Marshrutda statsionar radar besh yuz metrdan soʻng")
        XCTAssertEqual(uz(.camera(Call(kind: .tripod, form: .group, meters: 300))),
                       "Oldinda kameralar, uch yuz metr")
        XCTAssertEqual(uz(.camera(Call(kind: .mobileRadar, form: .full(.ahead), meters: 300, fromDrivers: true))),
                       "Haydovchilar belgisi, koʻchma radar oldinda, uch yuz metr")
        XCTAssertEqual(uz(.camera(Call(kind: .stationaryRadar, form: .full(.ahead), meters: 400,
                                       tail: .speedAndLimit(speed: 75, limit: 60)))),
                       "Statsionar radar oldinda, toʻrt yuz metr. Tezligingiz yetmish besh, cheklov oltmish")
        XCTAssertEqual(uz(.camera(Call(kind: .stationaryRadar, form: .full(.ahead), meters: 1300,
                                       tail: .limit(90)))),
                       "Statsionar radar oldinda, bir yarim kilometr, bu yerda toʻqson")
    }

    func testGroupPhraseDoesNotNameTheDriversMark() {
        // Групповая фраза — о нескольких камерах: атрибуцию одной из них не
        // выдаём за всю группу (как и текст).
        XCTAssertEqual(uz(.camera(Call(kind: .mobileRadar, form: .group, meters: 300, fromDrivers: true))),
                       "Oldinda kameralar, uch yuz metr")
    }

    func testRoutePhrasesInUzbek() {
        XCTAssertEqual(uz(.maneuver(.init(action: .turnRight, meters: 300, lanes: .leftOne))),
                       "Uch yuz metrdan soʻng, oʻngga buriling. Chap qatordan")
        XCTAssertEqual(uz(.maneuver(.init(action: .roundabout(exit: 2), meters: nil, lanes: nil))),
                       "Aylanada ikkinchi chiqish")
        XCTAssertNil(uz(.maneuver(.init(action: .roundabout(exit: 9), meters: nil, lanes: nil))),
                     "девятый съезд не записан — синтезатором")
        XCTAssertEqual(uz(.limitAhead(limit: 40, meters: 200)), "Ikki yuz metrdan soʻng tezlik cheklovi qirq")
        XCTAssertEqual(uz(.jam(meters: 1200, delaySeconds: 240)),
                       "Oldinda tirbandlik, taxminan bir kilometr, qoʻshimcha toʻrt daqiqa")
        XCTAssertEqual(uz(.detour(savingSeconds: 3900)),
                       "Oldinda tirbandlik. Bir soat besh daqiqa tezroq yoʻl bor")
        XCTAssertNil(uz(.detour(savingSeconds: 40)), "одни секунды — синтезатором")
        XCTAssertEqual(uz(.hotspot(.morning)), "Bu yerda tez-tez uchoyoq qoʻyiladi, odatda ertalab")
        XCTAssertEqual(uz(.phrase(.reportQueuedServer)), "Server javob bermayapti, keyinroq yuboraman")
        XCTAssertEqual(uz(.phrase(.roadClosureFromDrivers)), "Haydovchilar belgisi, oldinda yoʻl yopiq")
        XCTAssertEqual(uz(.phrase(.sample)), "Kamera, uch yuz metr")
    }

    /// Русский — тот же механизм со своей грамматикой: предлог внутри
    /// записи, «около» с родительным, женский род минут.
    func testRussianUsesItsOwnGrammar() {
        XCTAssertEqual(ru(.camera(Call(kind: .stationaryRadar, form: .full(.aheadLeft), meters: 500))),
                       "Стационарный радар впереди слева, пятьсот метров")
        XCTAssertEqual(ru(.camera(Call(kind: .dpsPost, form: .onRoute, meters: 400))),
                       "По маршруту пост ДПС через четыреста метров")
        XCTAssertEqual(ru(.limitAhead(limit: 40, meters: 200)), "Ограничение сорок через двести метров")
        XCTAssertEqual(ru(.jam(meters: 1000, delaySeconds: 60)),
                       "Впереди пробка, около километра, плюс одна минута")
        XCTAssertEqual(ru(.jam(meters: 300, delaySeconds: 22 * 60)),
                       "Впереди пробка, около трёхсот метров, плюс двадцать две минуты")
        XCTAssertEqual(ru(.detour(savingSeconds: 21 * 60)),
                       "Впереди пробка. Есть путь быстрее на двадцать одну минуту")
        XCTAssertEqual(ru(.detour(savingSeconds: 2 * 3600)), "Впереди пробка. Есть путь быстрее на два часа")
        XCTAssertEqual(ru(.phrase(.roadClosureFromDrivers)), "Отметка водителей, впереди перекрытие")
    }

    // MARK: - Сценарий целиком

    /// Всё, что приложение может сказать, собирается целиком на обоих языках,
    /// и у каждого отрывка есть текст и годное имя файла.
    func testEveryEventInTheSpaceComposesCompletely() {
        for language in VoiceLanguage.allCases {
            for event in VoiceScript.eventSpace {
                guard let ids = VoiceComposer.segments(for: event, in: language) else {
                    return XCTFail("\(language): не собирается \(event)")
                }
                XCTAssertFalse(ids.filter { !$0.isPause }.isEmpty, "\(event)")
                for id in ids where !id.isPause {
                    XCTAssertTrue(id.isValidFileName, id.raw)
                    XCTAssertNotNil(VoiceScript.text(id, language), "\(language): нет текста у \(id)")
                }
                XCTAssertNotNil(VoiceScript.text(of: ids, language: language))
            }
        }
    }

    /// Сценарий — это ровно то, что звучит: ни одной лишней записи, у
    /// каждой есть фраза-пример.
    func testScriptHasExamplesAndNothingUnused() {
        let lines = VoiceScript.lines(.uz)
        XCTAssertEqual(lines.map(\.id), VoiceScript.inventory(.uz))
        XCTAssertEqual(Set(lines.map(\.id)).count, lines.count)
        for line in lines {
            XCTAssertFalse(line.text.isEmpty, line.id.raw)
            XCTAssertFalse(line.example.isEmpty, line.id.raw)
            XCTAssertFalse(line.position.isEmpty, line.id.raw)
        }
        // План: 150–200 отрывков, 2–3 часа студии. Сильно больше — пересмотреть.
        XCTAssertGreaterThan(lines.count, 100)
        XCTAssertLessThanOrEqual(lines.count, 200)
    }

    /// script_uz.csv в репозитории совпадает с тем, что выводит код.
    /// Не совпал — `tools/voice_kit/export_script.sh`.
    func testScriptCSVMatchesCode() throws {
        for language in VoiceLanguage.allCases {
            let url = Self.root.appendingPathComponent("tools/voice_kit/script_\(language.rawValue).csv")
            let onDisk = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(onDisk, VoiceScript.csv(language),
                           "script_\(language.rawValue).csv устарел: запустите tools/voice_kit/export_script.sh \(language.rawValue)")
        }
    }

    func testScriptOrderIsNatural() {
        let ids: [SegmentID] = ["dist.100", "dist.50", "dist.300.after", "dist.300", "kind.radar", "num.5"]
        XCTAssertEqual(ids.sorted(by: VoiceScript.scriptOrder),
                       ["kind.radar", "num.5", "dist.50", "dist.100", "dist.300", "dist.300.after"])
    }

    // MARK: - 104 фразы docs/voice_phrases_uz.md

    private enum Coverage {
        /// Звучит — и собирается из отрывков целиком.
        case spoken(VoiceEvent)
        /// Только на экране: голос этого не говорит.
        case displayOnly(String)
        /// Имя собственное (улица, остановка): фраза целиком синтезатором.
        case properName
        /// Строки больше нет в приложении.
        case removed
    }

    private static let coverage: [String: Coverage] = {
        typealias M = VoiceEvent.ManeuverCall
        let full = { (side: VoiceEvent.Side) in
            Coverage.spoken(.camera(Call(kind: .stationaryRadar, form: .full(side), meters: 500)))
        }
        let lane = { (run: VoiceEvent.LaneRun) in
            Coverage.spoken(.maneuver(M(action: .turnLeft, meters: 300, lanes: run)))
        }
        let now = { (action: VoiceEvent.Action) in
            Coverage.spoken(.maneuver(M(action: action, meters: nil, lanes: nil)))
        }
        let violation = Coverage.displayOnly("нарушение в карточке камеры")
        let routeError = Coverage.displayOnly("ошибка маршрута на экране")
        let caption = Coverage.displayOnly("подпись HUD «до …»")
        return [
            " на %@": .properName,
            "%@ %@, %lld метров": full(.aheadRight),
            "%@, %lld метров": .spoken(.camera(Call(kind: .stationaryCamera, form: .brief, meters: 300))),
            "+%@ из-за пробок": .displayOnly("подпись варианта маршрута"),
            ", здесь %lld": .spoken(.camera(Call(kind: .stationaryRadar, form: .full(.ahead), meters: 500,
                                                 tail: .limit(60)))),
            ", через %@": .properName,
            ". Ваша скорость %lld": .spoken(.camera(Call(kind: .mobileRadar, form: .full(.ahead), meters: 300,
                                                         tail: .speed(75)))),
            ". Ваша скорость %lld, лимит %lld": .spoken(.camera(Call(kind: .stationaryRadar, form: .full(.ahead),
                                                                     meters: 400,
                                                                     tail: .speedAndLimit(speed: 75, limit: 60)))),
            "Быстрее на %@": .displayOnly("заголовок карточки объезда"),
            "Впереди пробка. Есть путь быстрее на %@": .spoken(.detour(savingSeconds: 480)),
            "Впереди пробка: около %1$@, плюс %2$@": .spoken(.jam(meters: 1000, delaySeconds: 240)),
            "Выезд на встречную полосу": violation,
            "ДТП": .spoken(.cameraName(.accident)),
            "Дорожные знаки и разметка": violation,
            "Ждём спутники": .spoken(.phrase(.reportNoPosition)),
            "Заезд за стоп-линию": violation,
            "Здесь часто ставят треногу": .spoken(.hotspot(nil)),
            "Здесь часто ставят треногу, %@": .spoken(.hotspot(.evening)),
            "Из двух левых рядов": lane(.leftTwo),
            "Из двух правых рядов": lane(.rightTwo),
            "Из левого ряда": lane(.leftOne),
            "Из левых рядов": lane(.leftMany),
            "Из любого ряда, кроме левого": lane(.allButLeft),
            "Из любого ряда, кроме правого": lane(.allButRight),
            "Из правого ряда": lane(.rightOne),
            "Из правых рядов": lane(.rightMany),
            "Из среднего ряда": lane(.middleOne),
            "Из средних рядов": lane(.middleMany),
            "Из трёх левых рядов": lane(.leftThree),
            "Из трёх правых рядов": lane(.rightThree),
            "Интеллектуальная камера + радар": .spoken(.cameraName(.intelligentRadar)),
            "Камера": .spoken(.camera(Call(kind: .stationaryCamera, form: .brief, meters: 300))),
            "Камеры впереди, %lld метров": .spoken(.camera(Call(kind: .stationaryCamera, form: .group, meters: 300))),
            "Маршрут не найден": routeError,
            "Маршрут не построился": .spoken(.phrase(.routeFailed)),
            "Маршрута уже нет — заезд не добавлен": routeError,
            "Маршруты временно недоступны — мы уже чиним": routeError,
            "Нарушение правил остановки": violation,
            "Нарушение правил стоянки": violation,
            "Не видим вашего положения — маршрут не построен": routeError,
            "Не вижу точного положения — маршрут пока не построить": .spoken(.phrase(.routeNoPosition)),
            "Не удалось заехать по пути — маршрут прежний": routeError,
            "Нет связи": .spoken(.phrase(.offline)),
            "Нет связи с сервером маршрутов — проверьте интернет": routeError,
            "Нет связи, отправлю позже": .spoken(.phrase(.reportQueuedOffline)),
            "Объезд пробки": .displayOnly("подпись карточки объезда"),
            "Объезд пробки · через %@": .displayOnly("подпись карточки объезда"),
            "Ограничение %1$lld через %2$@": .spoken(.limitAhead(limit: 40, meters: 200)),
            "Отметка водителей: %@": .spoken(.camera(Call(kind: .mobileRadar, form: .full(.ahead), meters: 300,
                                                          fromDrivers: true))),
            "Отметка ставится в движении": .spoken(.phrase(.reportNotDriving)),
            "Отметки сейчас выключены": .spoken(.phrase(.reportsDisabled)),
            "Отмечали %lld раз, в разные дни: %lld": .removed,
            "Отмечен водителями, исчезнет ~%@": .displayOnly("подпись отметки на карте"),
            "Передвижной радар": .spoken(.cameraName(.mobileRadar)),
            "По маршруту %@ через %lld метров": .spoken(.camera(Call(kind: .stationaryRadar, form: .onRoute,
                                                                     meters: 500))),
            "Подтвердили, спасибо": .spoken(.phrase(.reportConfirmed)),
            "Пост ДПС": .spoken(.cameraName(.dpsPost)),
            "Превышение скорости": .spoken(.phrase(.overspeed)),
            "Принято, спасибо": .spoken(.phrase(.reportAccepted)),
            "Проезд на красный": violation,
            "Радар": .spoken(.camera(Call(kind: .stationaryRadar, form: .brief, meters: 300))),
            "Ремень безопасности": violation,
            "Сервер не отвечает": .spoken(.phrase(.serverDown)),
            "Сервер отклонил отметку": .spoken(.phrase(.reportRefused)),
            "Слишком часто, подождите минуту": .spoken(.phrase(.tooOften)),
            "Стационарная камера": .spoken(.cameraName(.stationaryCamera)),
            "Стационарный радар": .spoken(.cameraName(.stationaryRadar)),
            "Странный ответ сервера": .spoken(.phrase(.badAnswer)),
            "Тип уточнён": .spoken(.phrase(.reportAmended)),
            "Тренога": .spoken(.cameraName(.tripod)),
            "Уже отметили здесь": .spoken(.phrase(.reportDuplicate)),
            "Через %lld метров — %@": .spoken(.maneuver(M(action: .turnRight, meters: 300, lanes: nil))),
            "без пробок": .displayOnly("подпись варианта маршрута"),
            "впереди": full(.ahead),
            "впереди слева": full(.aheadLeft),
            "впереди справа": full(.aheadRight),
            "вы прибыли": now(.arrived),
            "держитесь левее": now(.keepLeft),
            "держитесь правее": now(.keepRight),
            "до ДТП": caption,
            "до камеры": caption,
            "до передв. радара": caption,
            "до поста ДПС": caption,
            "до радара": caption,
            "до точки": caption,
            "до треноги": caption,
            "заезд: %@": .properName,
            "круто налево": now(.sharpLeft),
            "круто направо": now(.sharpRight),
            "на кольце %lld-й съезд": now(.roundabout(exit: 2)),
            "обычно %@": .displayOnly("подпись «Куда» в CarPlay"),
            "обычно вечером": .spoken(.hotspot(.evening)),
            "обычно днём": .spoken(.hotspot(.day)),
            "обычно ночью": .spoken(.hotspot(.night)),
            "обычно утром": .spoken(.hotspot(.morning)),
            "перестройтесь в поток": now(.merge),
            "плавно левее": now(.slightLeft),
            "плавно правее": now(.slightRight),
            "по вашим поездкам": .displayOnly("подпись «Куда» в CarPlay"),
            "поверните налево": now(.turnLeft),
            "поверните направо": now(.turnRight),
            "разворот": now(.uturn),
            "сверните на съезд": now(.offRamp),
            "съезд на развязку": now(.onRamp),
        ]
    }()

    private static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Подстановка формата: %@, %lld, %1$@, %2$lld.
    private static let placeholder = try! NSRegularExpression(pattern: "%([0-9]+[$])?(@|lld)")

    /// Первая таблица документа: русский шаблон → узбекский.
    private static func docTemplates() throws -> [(ru: String, uz: String)] {
        let text = try String(contentsOf: root.appendingPathComponent("docs/voice_phrases_uz.md"), encoding: .utf8)
        var rows: [(String, String)] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## "), !rows.isEmpty { break }
            guard line.hasPrefix("| "), !line.hasPrefix("| Русский"), !line.hasPrefix("|---") else { continue }
            let cells = line.components(separatedBy: "|")
            guard cells.count >= 4 else { continue }
            rows.append((String(cells[1].dropFirst().dropLast()), String(cells[2].dropFirst().dropLast())))
        }
        return rows
    }

    /// Только буквы и цифры, без регистра: апострофы оʻ/o'/o‘, знаки и
    /// пробелы в записи не слышны.
    private static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0)
            || CharacterSet.decimalDigits.contains($0) }.map(Character.init))
            // ʻ и ʼ — «буквы-модификаторы» Юникода, CharacterSet.letters их пропускает.
            .replacingOccurrences(of: "ʻ", with: "").replacingOccurrences(of: "ʼ", with: "")
    }

    func testEveryDocTemplateIsClassified() throws {
        let rows = try Self.docTemplates()
        XCTAssertEqual(rows.count, 104, "в документе 104 шаблона")
        XCTAssertEqual(Set(rows.map(\.ru)), Set(Self.coverage.keys),
                       "каждая фраза документа классифицирована, и лишних нет")
    }

    /// Звучащая фраза документа собирается целиком, и все её неизменные
    /// слова (между подстановками) слышны в записи в том же порядке.
    func testEverySpokenDocTemplateIsCoveredBySegments() throws {
        var spoken = 0
        for row in try Self.docTemplates() {
            guard case .spoken(let event)? = Self.coverage[row.ru] else { continue }
            spoken += 1
            guard let ids = VoiceComposer.segments(for: event, in: .uz),
                  let said = VoiceScript.text(of: ids, language: .uz) else {
                XCTFail("«\(row.ru)» не собирается: \(event)")
                continue
            }
            var heard = Self.normalized(said)[...]
            let marked = Self.placeholder.stringByReplacingMatches(
                in: row.uz, range: NSRange(row.uz.startIndex..., in: row.uz), withTemplate: "\u{1}")
            let literals = marked.components(separatedBy: "\u{1}").map(Self.normalized).filter { !$0.isEmpty }
            for literal in literals {
                guard let range = heard.range(of: literal) else {
                    XCTFail("«\(row.ru)» → «\(said)»: нет «\(literal)» из «\(row.uz)»")
                    break
                }
                heard = heard[range.upperBound...]
            }
            XCTAssertNotNil(VoiceComposer.segments(for: event, in: .ru), "«\(row.ru)» не собирается по-русски")
        }
        XCTAssertGreaterThanOrEqual(spoken, 70)
    }
}
