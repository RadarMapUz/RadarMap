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
            .appendingPathComponent(VoicePack.directoryName(.uz, placeholder: true))
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

    /// Пока настоящей записи нет, «записанный голос» не предлагается: заглушка
    /// берётся только по отладочному переключателю.
    func testPlaceholderIsNotOfferedWithoutTheDebugSwitch() throws {
        let root = try XCTUnwrap(Bundle.main.resourceURL)
        let offered = VoicePack.discover(language: .uz, allowPlaceholder: false, in: root)
        XCTAssertFalse(offered?.isPlaceholder ?? false)
        XCTAssertEqual(VoicePack.discover(language: .uz, allowPlaceholder: true, in: root)?.language, .uz)
        XCTAssertNil(VoicePack.discover(language: .ru, allowPlaceholder: true, in: root), "русского пакета нет")
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
