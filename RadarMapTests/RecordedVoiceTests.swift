//
//  RecordedVoiceTests.swift
//  RadarMapTests
//
//  Записанный голос (этап 16.3–16.5): пакет, раскодирование, склейка,
//  задержка — и главное правило: нет отрывка, битый файл, текст разошёлся
//  с событием → фраза ЦЕЛИКОМ синтезатором. Ни молчания, ни полфразы.
//

import AVFoundation
import XCTest
@testable import RadarMap

final class RecordedVoiceTests: XCTestCase {

    private typealias Call = VoiceEvent.CameraCall

    /// Пакет-заглушка из бандла (только отладочная сборка — в выпуск не едет).
    private func placeholder() throws -> VoicePack {
        let url = try XCTUnwrap(Bundle.main.resourceURL)
            .appendingPathComponent(VoicePack.placeholderDirectoryName(.uz))
        return try VoicePack.load(from: url)
    }

    /// Копия пакета во временной папке — чтобы портить её без вреда.
    private func scratchCopy(of pack: VoicePack) throws -> URL {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).bundle")
        try FileManager.default.copyItem(at: pack.directory, to: target)
        addTeardownBlock { try? FileManager.default.removeItem(at: target) }
        return target
    }

    // MARK: - Настройка

    func testVoiceSourceDefaultsToRecordedOnlyWithAPack() {
        XCTAssertEqual(VoiceSource.effective(choice: nil, packAvailable: false), .system)
        XCTAssertEqual(VoiceSource.effective(choice: .recorded, packAvailable: false), .system,
                       "выбор записи без пакета — системный голос, а не тишина")
        XCTAssertEqual(VoiceSource.effective(choice: nil, packAvailable: true), .recorded)
        XCTAssertEqual(VoiceSource.effective(choice: .system, packAvailable: true), .system)
    }

    // MARK: - Решение «запись или синтезатор»

    func testDecisionNeedsMatchingTextAndEverySegment() {
        let event = VoiceEvent.camera(Call(kind: .stationaryRadar, form: .brief, meters: 300))
        let all = Set(VoiceScript.inventory(.uz))
        XCTAssertEqual(RecordedVoicePlan.decide(text: "Радар, 300 метров", event: event, rendered: "Радар, 300 метров",
                                                language: .uz, available: all),
                       .success(["kind.radar", .comma, "dist.300"]))
        XCTAssertEqual(RecordedVoicePlan.decide(text: "Радар, 300 метров, здесь 60", event: event,
                                                rendered: "Радар, 300 метров", language: .uz, available: all),
                       .failure(.textMismatch), "событие не договаривает фразу — синтезатор")
        XCTAssertEqual(RecordedVoicePlan.decide(text: "x", event: event, rendered: "x", language: .uz,
                                                available: all.subtracting(["dist.300"])),
                       .failure(.missingSegments), "нет одного отрывка — вся фраза синтезатором")
        let zero = VoiceEvent.camera(Call(kind: .stationaryRadar, form: .brief, meters: 0))
        XCTAssertEqual(RecordedVoicePlan.decide(text: "x", event: zero, rendered: "x", language: .uz, available: all),
                       .failure(.missingSegments), "«0 метров» не записано")
    }

    // MARK: - Пакет-заглушка

    func testPlaceholderPackIsCompleteAndMarked() throws {
        let pack = try placeholder()
        XCTAssertTrue(pack.isPlaceholder)
        XCTAssertEqual(pack.language, .uz)
        XCTAssertEqual(pack.manifest.sampleRate, 48000)
        XCTAssertEqual(pack.segmentIDs, Set(VoiceScript.inventory(.uz)),
                       "заглушка собрана по текущему сценарию: make_placeholder.py")
        let bytes = try pack.segmentIDs.reduce(0) { total, id in
            total + (try FileManager.default.attributesOfItem(atPath: pack.url(for: id)!.path)[.size] as? Int ?? 0)
        }
        XCTAssertLessThanOrEqual(bytes, 3 * 1024 * 1024, "бюджет пакета — 3 МБ")
    }

    /// Заглушка — только по отладочному переключателю и только когда
    /// настоящих наборов нет: настоящий набор главнее.
    func testPlaceholderIsNotOfferedWithoutTheDebugSwitch() throws {
        let root = try fakeRoot(genders: [], placeholder: true)
        XCTAssertNil(VoicePack.discover(language: .uz, gender: .female, allowPlaceholder: false, in: root))
        XCTAssertEqual(VoicePack.discover(language: .uz, gender: .female, allowPlaceholder: true, in: root)?
            .isPlaceholder, true)
        XCTAssertNil(VoicePack.discover(language: .ru, gender: .female, allowPlaceholder: true, in: root),
                     "русского пакета нет")
        let both = try fakeRoot(genders: [.female, .male], placeholder: true)
        XCTAssertEqual(VoicePack.discover(language: .uz, gender: .female, allowPlaceholder: true, in: both)?
            .isPlaceholder, false, "настоящий набор главнее заглушки")
    }

    // MARK: - Два голоса (28.M: озвучка Navoiy TTS)

    /// Папка-«бандл» во временном каталоге: копии заглушки под именами
    /// настоящих наборов (с `placeholder: false`) и, по желанию, сама заглушка.
    private func fakeRoot(genders: [VoiceGender], placeholder includePlaceholder: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = try placeholder().directory
        for gender in genders {
            let target = root.appendingPathComponent(VoicePack.directoryName(.uz, gender: gender))
            try FileManager.default.copyItem(at: source, to: target)
            let url = target.appendingPathComponent("manifest.json")
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            json["placeholder"] = false
            json["voice"] = gender.rawValue
            try JSONSerialization.data(withJSONObject: json).write(to: url)
        }
        if includePlaceholder {
            try FileManager.default.copyItem(at: source,
                                             to: root.appendingPathComponent(VoicePack.placeholderDirectoryName(.uz)))
        }
        return root
    }

    private func corrupt(_ segment: String, gender: VoiceGender, in root: URL) throws {
        let file = root.appendingPathComponent(VoicePack.directoryName(.uz, gender: gender))
            .appendingPathComponent(segment + ".m4a")
        var bytes = try Data(contentsOf: file)
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: file)
    }

    func testChosenGenderIsUsedAndTheOtherIsTheFallback() throws {
        let root = try fakeRoot(genders: [.female, .male], placeholder: false)
        XCTAssertEqual(VoicePack.discover(language: .uz, gender: .female, allowPlaceholder: false, in: root)?.gender,
                       .female)
        XCTAssertEqual(VoicePack.discover(language: .uz, gender: .male, allowPlaceholder: false, in: root)?.gender,
                       .male)
        XCTAssertEqual(VoicePack.availableGenders(language: .uz, in: root), [.female, .male])

        let onlyMale = try fakeRoot(genders: [.male], placeholder: false)
        XCTAssertEqual(VoicePack.discover(language: .uz, gender: .female, allowPlaceholder: false, in: onlyMale)?
            .gender, .male, "выбранного набора нет — второй, а не синтезатор")
        XCTAssertEqual(VoicePack.availableGenders(language: .uz, in: onlyMale), [.male])
    }

    func testBrokenChosenPackFallsBackToTheIntactOne() throws {
        let root = try fakeRoot(genders: [.female, .male], placeholder: false)
        try corrupt("kind.radar", gender: .female, in: root)
        let pack = try XCTUnwrap(VoicePack.discover(language: .uz, gender: .female, allowPlaceholder: false, in: root))
        XCTAssertEqual(pack.gender, .male, "битый выбранный набор — целый второй")
        XCTAssertTrue(pack.segmentIDs.contains("kind.radar"))

        // Манифест выбранного не читается — тоже второй.
        let unreadable = try fakeRoot(genders: [.female, .male], placeholder: false)
        try Data("{".utf8).write(to: unreadable.appendingPathComponent(VoicePack.directoryName(.uz, gender: .female))
            .appendingPathComponent("manifest.json"))
        XCTAssertEqual(VoicePack.discover(language: .uz, gender: .female, allowPlaceholder: false, in: unreadable)?
            .gender, .male)
    }

    /// Оба набора битые — звучит тот, где уцелело больше, без битых
    /// отрывков: фраза с битым целиком уходит синтезатору, тишины нет.
    func testBothPacksBrokenLeaveOnlyIntactSegmentsAndSynthesizerForTheRest() throws {
        let root = try fakeRoot(genders: [.female, .male], placeholder: false)
        try corrupt("kind.radar", gender: .female, in: root)
        try corrupt("kind.radar", gender: .male, in: root)
        try corrupt("dist.300", gender: .male, in: root)
        let pack = try XCTUnwrap(VoicePack.discover(language: .uz, gender: .male, allowPlaceholder: false, in: root))
        XCTAssertEqual(pack.gender, .female, "у женского уцелело больше")
        XCTAssertFalse(pack.segmentIDs.contains("kind.radar"))
        let radar = VoiceEvent.camera(Call(kind: .stationaryRadar, form: .brief, meters: 300))
        XCTAssertNil(RecordedVoicePlan.segments(for: radar, language: .uz, available: pack.segmentIDs),
                     "фраза с битым отрывком — синтезатором целиком")
        XCTAssertNotNil(RecordedVoicePlan.segments(for: .phrase(.overspeed), language: .uz,
                                                   available: pack.segmentIDs))
        XCTAssertNil(VoicePack.discover(language: .uz, gender: .male, allowPlaceholder: false,
                                        in: try fakeRoot(genders: [], placeholder: false)),
                     "наборов нет — синтезатор")
    }

    /// Сменили голос — кэш раскодированных отрывков прежнего набора не
    /// используется: два диктора в одной фразе не звучат.
    func testSwitchingPacksDropsTheDecodedCache() throws {
        let root = try fakeRoot(genders: [.female, .male], placeholder: false)
        let female = try VoicePack.load(from: root.appendingPathComponent(VoicePack.directoryName(.uz, gender: .female)))
        let male = try VoicePack.load(from: root.appendingPathComponent(VoicePack.directoryName(.uz, gender: .male)))
        let ids: [SegmentID] = ["kind.radar", .comma, "dist.300"]
        let player = SegmentPlayer()
        XCTAssertNoThrow(try player.prepare(ids, pack: female))
        try corrupt("kind.radar", gender: .male, in: root)
        XCTAssertThrowsError(try player.prepare(ids, pack: male), "отрывок взят из мужского набора, не из кэша женского") {
            XCTAssertEqual($0 as? SegmentPlayer.PlayError, .segment("kind.radar", .shaMismatch))
        }
    }

    @MainActor
    func testVoiceGenderDefaultsToFemaleAndPersists() {
        XCTAssertEqual(VoiceGender.female.other, .male)
        XCTAssertEqual(VoiceGender.male.other, .female)
        let defaults = UserDefaults.standard
        let key = "voiceGender"
        let saved = defaults.object(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        defaults.removeObject(forKey: key)
        XCTAssertEqual(AppSettings().voiceGender, .female, "по умолчанию — женский")
        for gender in VoiceGender.allCases {
            AppSettings().voiceGender = gender
            XCTAssertEqual(AppSettings().voiceGender, gender, "выбор сохраняется")
        }
    }

    /// Наборы `voice-uz-female.bundle` и `voice-uz-male.bundle` едут в выпуск:
    /// полные по сценарию, не заглушки, каждый в бюджете 3 МБ, целые.
    func testShippedPacksAreCompleteIntactAndInBudget() throws {
        let root = try XCTUnwrap(Bundle.main.resourceURL)
        XCTAssertEqual(VoicePack.availableGenders(language: .uz, in: root), [.female, .male])
        for gender in VoiceGender.allCases {
            let pack = try VoicePack.load(from: root.appendingPathComponent(VoicePack.directoryName(.uz, gender: gender)))
            XCTAssertFalse(pack.isPlaceholder, gender.rawValue)
            XCTAssertEqual(pack.language, .uz)
            XCTAssertEqual(pack.manifest.sampleRate, 48000)
            XCTAssertEqual(pack.segmentIDs, Set(VoiceScript.inventory(.uz)), "\(gender): собран по текущему сценарию")
            XCTAssertEqual(pack.corruptSegments(), [], gender.rawValue)
            let bytes = try pack.segmentIDs.reduce(0) { total, id in
                total + (try FileManager.default.attributesOfItem(atPath: pack.url(for: id)!.path)[.size] as? Int ?? 0)
            }
            XCTAssertLessThanOrEqual(bytes, 3 * 1024 * 1024, "\(gender): бюджет набора — 3 МБ")
            for allow in [false, true] {
                let found = try XCTUnwrap(VoicePack.discover(language: .uz, gender: gender, allowPlaceholder: allow, in: root))
                XCTAssertEqual(found.gender, gender, "выбранный голос (allowPlaceholder: \(allow))")
                XCTAssertFalse(found.isPlaceholder)
            }
        }
        XCTAssertEqual(VoiceSource.effective(choice: nil, packAvailable: true), .recorded,
                       "с набором узбекский по умолчанию звучит записью")
    }

    /// С настоящими наборами фразы образцов идут записью: план — отрывки, а
    /// не синтезатор, склейка — длина отрывков плюс паузы.
    func testShippedPacksPlanAndPrepareRecordedPhrases() throws {
        let root = try XCTUnwrap(Bundle.main.resourceURL)
        let events: [VoiceEvent] = [
            .camera(Call(kind: .stationaryRadar, form: .full(.aheadRight), meters: 500)),
            .maneuver(.init(action: .turnRight, meters: 300, lanes: nil)),
            .phrase(.overspeed),
            .limitAhead(limit: 60, meters: 200),
            .jam(meters: 800, delaySeconds: 240),
            .phrase(.reportAccepted),
        ]
        for gender in VoiceGender.allCases {
            let pack = try XCTUnwrap(VoicePack.discover(language: .uz, gender: gender, allowPlaceholder: false, in: root))
            let player = SegmentPlayer()
            for event in events {
                let rendered = VoiceText.render(event)
                let decided = RecordedVoicePlan.decide(text: rendered, event: event, rendered: rendered,
                                                       language: .uz, available: pack.segmentIDs)
                guard case .success(let ids) = decided else { return XCTFail("\(gender) \(event): \(decided)") }
                let buffer = try player.prepare(ids, pack: pack)
                XCTAssertEqual(Double(buffer.frameLength) / 48000, pack.duration(of: ids)
                               + Double(ids.filter { $0 == .comma }.count) * AppConfig.voicePauseCommaSeconds
                               + Double(ids.filter { $0 == .stop }.count) * AppConfig.voicePauseStopSeconds,
                               accuracy: 0.01, "\(gender) \(ids)")
            }
            for id in pack.segmentIDs {
                let buffer = try SegmentDecoder.decode(id, in: pack)
                XCTAssertEqual(Double(buffer.frameLength) / buffer.format.sampleRate,
                               pack.manifest.segments[id.raw]!.duration, accuracy: 0.002, "\(gender) \(id)")
            }
        }
    }

    func testEverySegmentDecodesToItsManifestDuration() throws {
        let pack = try placeholder()
        for id in pack.segmentIDs {
            let buffer = try SegmentDecoder.decode(id, in: pack)
            XCTAssertEqual(buffer.format.sampleRate, 48000)
            XCTAssertEqual(buffer.format.channelCount, 1)
            let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
            XCTAssertEqual(seconds, pack.manifest.segments[id.raw]!.duration, accuracy: 0.002,
                           "\(id): задержка кодера учтена — на стыке нет паузы")
        }
    }

    // MARK: - Подмена: удалённый и битый отрывок

    func testDeletedSegmentSendsThePhraseToTheSynthesizer() throws {
        let copy = try scratchCopy(of: placeholder())
        try FileManager.default.removeItem(at: copy.appendingPathComponent("dist.300.m4a"))
        let pack = try VoicePack.load(from: copy)
        XCTAssertFalse(pack.segmentIDs.contains("dist.300"))
        let needsIt = VoiceEvent.camera(Call(kind: .stationaryRadar, form: .brief, meters: 300))
        let other = VoiceEvent.camera(Call(kind: .stationaryRadar, form: .brief, meters: 500))
        XCTAssertNil(RecordedVoicePlan.segments(for: needsIt, language: .uz, available: pack.segmentIDs),
                     "фраза с удалённым отрывком — синтезатором целиком")
        XCTAssertNotNil(RecordedVoicePlan.segments(for: other, language: .uz, available: pack.segmentIDs),
                        "остальные фразы — записью")
        // Даже если план сочли бы годным — плеер не сыграет полфразы.
        XCTAssertThrowsError(try SegmentPlayer().prepare(["kind.radar", .comma, "dist.300"], pack: try placeholderCopyListing(copy)))
    }

    /// Пакет, в манифесте которого отрывок есть, а файла уже нет (удалили
    /// после загрузки) — подготовка фразы обязана упасть, а не склеить остаток.
    private func placeholderCopyListing(_ copy: URL) throws -> VoicePack {
        let full = try placeholder()
        return VoicePack(directory: copy, manifest: full.manifest, segmentIDs: full.segmentIDs)
    }

    func testCorruptedSegmentFailsTheWholePhrase() throws {
        let copy = try scratchCopy(of: placeholder())
        let file = copy.appendingPathComponent("kind.radar.m4a")
        var bytes = try Data(contentsOf: file)
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: file)
        let pack = try VoicePack.load(from: copy)
        let ids = try XCTUnwrap(VoiceComposer.segments(
            for: .camera(Call(kind: .stationaryRadar, form: .brief, meters: 300)), in: .uz))
        XCTAssertThrowsError(try SegmentPlayer().prepare(ids, pack: pack)) { error in
            XCTAssertEqual(error as? SegmentPlayer.PlayError, .segment("kind.radar", .shaMismatch))
        }
    }

    func testManifestWithForeignPathOrFormatIsRefused() throws {
        let copy = try scratchCopy(of: placeholder())
        let url = copy.appendingPathComponent("manifest.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var segments = try XCTUnwrap(json["segments"] as? [String: Any])
        var entry = try XCTUnwrap(segments["kind.radar"] as? [String: Any])
        entry["file"] = "../kind.radar.m4a"
        segments["kind.radar"] = entry
        json["segments"] = segments
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        XCTAssertFalse(try VoicePack.load(from: copy).segmentIDs.contains("kind.radar"),
                       "путь из манифеста не выводит за пакет")
        json["format"] = 99
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        XCTAssertThrowsError(try VoicePack.load(from: copy))
    }

    // MARK: - Склейка и задержка

    func testJoinIsSampleExact() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                                                 channels: 1, interleaved: false))
        func ramp(_ count: Int, from start: Float) -> AVAudioPCMBuffer {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            for i in 0..<count { buffer.floatChannelData![0][i] = start + Float(i) }
            return buffer
        }
        let silence = try XCTUnwrap(SegmentPlayer.silence(seconds: 0.01, format: format))
        XCTAssertEqual(silence.frameLength, 480)
        let joined = try XCTUnwrap(SegmentPlayer.join([ramp(100, from: 0), silence, ramp(50, from: 1000)]))
        XCTAssertEqual(joined.frameLength, 630)
        let samples = joined.floatChannelData![0]
        XCTAssertEqual(samples[99], 99)
        XCTAssertEqual(samples[100], 0)
        XCTAssertEqual(samples[579], 0)
        XCTAssertEqual(samples[580], 1000, "второй отрывок — сразу за паузой, без зазора")
        let other = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100,
                                                channels: 1, interleaved: false))
        let foreign = AVAudioPCMBuffer(pcmFormat: other, frameCapacity: 10)!
        foreign.frameLength = 10
        XCTAssertNil(SegmentPlayer.join([ramp(10, from: 0), foreign]), "разные форматы не склеиваются")
    }

    func testFadeEdgesStartAndEndAtZero() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                                                 channels: 1, interleaved: false))
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        for i in 0..<4800 { buffer.floatChannelData![0][i] = 0.5 }
        SegmentDecoder.fadeEdges(buffer, seconds: 0.004)
        let samples = buffer.floatChannelData![0]
        XCTAssertEqual(samples[0], 0)
        XCTAssertEqual(samples[4799], 0)
        XCTAssertEqual(samples[2400], 0.5, "середина не тронута")
    }

    /// Склейка через настоящий AVAudioPlayerNode (рендер вне реального
    /// времени): на выходе ровно склеенная фраза — без зазоров и без потерь.
    func testPlayerNodeRendersTheJoinedPhraseGapless() throws {
        let pack = try placeholder()
        let ids = try XCTUnwrap(VoiceComposer.segments(
            for: .camera(Call(kind: .stationaryCamera, form: .brief, meters: 300)), in: .uz))
        let phrase = try SegmentPlayer().prepare(ids, pack: pack)
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: phrase.format)
        try engine.enableManualRenderingMode(.offline, format: phrase.format, maximumFrameCount: 4096)
        try engine.start()
        node.scheduleBuffer(phrase, at: nil)
        node.play()
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                                    frameCapacity: engine.manualRenderingMaximumFrameCount))
        var rendered: [Float] = []
        while rendered.count < Int(phrase.frameLength) {
            let status = try engine.renderOffline(output.frameCapacity, to: output)
            XCTAssertEqual(status, .success)
            rendered += UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))
        }
        engine.stop()
        let source = UnsafeBufferPointer(start: phrase.floatChannelData![0], count: Int(phrase.frameLength))
        var worst: Float = 0
        for i in 0..<source.count { worst = max(worst, abs(rendered[i] - source[i])) }
        XCTAssertLessThan(worst, 1e-4, "плеер выдаёт склейку сэмпл в сэмпл")
    }

    /// Бюджет до первого звука — 150 мс. Здесь мерится наша часть:
    /// раскодирование и склейка типичной фразы с холодным кэшем (на
    /// устройстве к ней добавляются активация сессии и старт движка — их
    /// пишет журнал «записанный голос: до первого звука …»).
    func testColdPreparationFitsTheLatencyBudget() throws {
        let pack = try placeholder()
        let ids = try XCTUnwrap(VoiceComposer.segments(
            for: .camera(Call(kind: .stationaryRadar, form: .full(.aheadRight), meters: 500,
                              tail: .speedAndLimit(speed: 85, limit: 60))), in: .uz))
        let player = SegmentPlayer()
        // Как в приложении: декодер AAC прогрет при чтении пакета
        // (AlertPlayer → SegmentPlayer.warm), кэш фраз пуст.
        player.warm("p.thanks", pack: pack)
        var perFile: [Double] = []
        for id in ["p.offline", "p.closure", "p.trip_ended"] as [SegmentID] {
            let t = DispatchTime.now().uptimeNanoseconds
            _ = try SegmentDecoder.decode(id, in: pack)
            perFile.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
        }
        print("записанный голос: раскодирование отрывка \(perFile) мс")
        let cold = DispatchTime.now().uptimeNanoseconds
        let phrase = try player.prepare(ids, pack: pack)
        let coldMs = Double(DispatchTime.now().uptimeNanoseconds - cold) / 1e6
        let warm = DispatchTime.now().uptimeNanoseconds
        _ = try player.prepare(ids, pack: pack)
        let warmMs = Double(DispatchTime.now().uptimeNanoseconds - warm) / 1e6
        print("записанный голос: склейка \(ids.count) частей, холодная \(coldMs) мс, из кэша \(warmMs) мс")
        XCTAssertLessThan(coldMs, AppConfig.voiceFirstSoundBudgetMs)
        XCTAssertLessThan(warmMs, 20)
        let expected = ids.reduce(0.0) { total, id in
            total + (id == .stop ? AppConfig.voicePauseStopSeconds
                     : id == .comma ? AppConfig.voicePauseCommaSeconds
                     : pack.manifest.segments[id.raw]!.duration)
        }
        XCTAssertEqual(Double(phrase.frameLength) / 48000, expected, accuracy: 0.002)
    }

    func testCacheEvictsLeastRecentlyUsedWithinBudget() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                                                 channels: 1, interleaved: false))
        func buffer() -> AVAudioPCMBuffer {
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1000)!
            b.frameLength = 1000
            return b
        }
        var cache = SegmentCache(budgetBytes: 10_000)   // два буфера по 4000 байт
        cache["a"] = buffer()
        cache["b"] = buffer()
        _ = cache["a"]                                  // «a» свежее «b»
        cache["c"] = buffer()
        XCTAssertNotNil(cache["a"])
        XCTAssertNil(cache["b"], "дольше всех не звучавший уходит первым")
        XCTAssertNotNil(cache["c"])
        XCTAssertLessThanOrEqual(cache.bytes, 10_000)
    }
}
