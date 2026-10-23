//
//  VoicePack.swift
//  RadarMap
//
//  Пакет записанного голоса (этап 16.3): папка `voice-<язык>-<голос>.bundle`
//  в приложении (`voice-uz-female.bundle`, `voice-uz-male.bundle` — 28.M) —
//  `manifest.json` и по файлу AAC на отрывок.
//
//  Пакет едет внутри подписанного приложения, поэтому sha256 в манифесте —
//  не защита от злоумышленника (её даёт подпись сборки), а проверка
//  целостности: битый или подменённый при сборке файл не должен прозвучать
//  обрывком. Любая неисправность — нет файла, sha не сходится, не
//  раскодировался — означает одно: фраза идёт синтезатором ЦЕЛИКОМ.
//
//  Заглушка (`voice-<язык>-placeholder.bundle`, `placeholder: true`) — тот же
//  формат, собранный синтезатором macOS до записи диктора. В Release её нет
//  в сборке вовсе (EXCLUDED_SOURCE_FILE_NAMES), а пакет с пометкой заглушки
//  отвергается и при случайной подмене имени.
//

import AVFoundation
import CryptoKit
import Foundation
import os

/// manifest.json пакета (пишет tools/voice_kit/build_pack.py).
nonisolated struct VoicePackManifest: Codable, Equatable, Sendable {
    struct Segment: Codable, Equatable, Sendable {
        /// Имя файла внутри пакета.
        let file: String
        /// Длительность, с — для сторожа зависшей фразы.
        let duration: Double
        let sha256: String
    }

    /// Версия формата манифеста.
    let format: Int
    let language: String
    /// Пакет-заглушка (синтезатор вместо диктора).
    let placeholder: Bool
    let sampleRate: Double
    let channels: Int
    /// Кто говорит (для экрана настроек и журнала).
    let voice: String?
    let segments: [String: Segment]

    static let currentFormat = 1
}

nonisolated struct VoicePack: Sendable {

    enum LoadError: Error, Equatable {
        case noManifest
        case badManifest(String)
    }

    let directory: URL
    let manifest: VoicePackManifest
    /// Отрывки, файлы которых на месте (sha проверяется при раскодировании).
    let segmentIDs: Set<SegmentID>
    /// Чей голос — женский или мужской набор; nil у заглушки.
    var gender: VoiceGender? = nil

    var isPlaceholder: Bool { manifest.placeholder }
    var language: VoiceLanguage? { VoiceLanguage(rawValue: manifest.language) }

    func url(for id: SegmentID) -> URL? {
        guard let entry = manifest.segments[id.raw] else { return nil }
        return directory.appendingPathComponent(entry.file)
    }

    func duration(of ids: [SegmentID]) -> Double {
        ids.reduce(0) { $0 + (manifest.segments[$1.raw]?.duration ?? 0) }
    }

    /// Имя папки набора в бандле: `voice-uz-female.bundle`, `voice-uz-male.bundle`.
    static func directoryName(_ language: VoiceLanguage, gender: VoiceGender) -> String {
        "voice-\(language.rawValue)-\(gender.rawValue).bundle"
    }

    /// Имя папки заглушки (только отладочная сборка).
    static func placeholderDirectoryName(_ language: VoiceLanguage) -> String {
        "voice-\(language.rawValue)-placeholder.bundle"
    }

    /// Отрывки, чей файл не сходится с sha манифеста. Чтение ~150 мелких
    /// файлов (~1,5 МБ) — миллисекунды, и только вне главного потока.
    func corruptSegments() -> Set<SegmentID> {
        var bad = Set<SegmentID>()
        for id in segmentIDs {
            guard let url = url(for: id), let entry = manifest.segments[id.raw],
                  let data = try? Data(contentsOf: url),
                  SegmentDecoder.sha256Hex(of: data) == entry.sha256.lowercased() else {
                bad.insert(id)
                continue
            }
        }
        return bad
    }

    /// Тот же набор без отрывков из `ids`: фраза с ними пойдёт синтезатором.
    func excluding(_ ids: Set<SegmentID>) -> VoicePack {
        VoicePack(directory: directory, manifest: manifest, segmentIDs: segmentIDs.subtracting(ids), gender: gender)
    }

    /// Полон ли набор: есть каждый отрывок сценария языка.
    func isComplete(_ inventory: Set<SegmentID>) -> Bool {
        inventory.isSubset(of: segmentIDs)
    }

    /// Прочитать пакет. Отрывок без файла в набор не входит — фраза с ним
    /// пойдёт синтезатором, остальные звучат записью.
    static func load(from directory: URL) throws -> VoicePack {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else { throw LoadError.noManifest }
        let manifest: VoicePackManifest
        do {
            manifest = try JSONDecoder().decode(VoicePackManifest.self, from: data)
        } catch {
            throw LoadError.badManifest(error.localizedDescription)
        }
        guard manifest.format == VoicePackManifest.currentFormat else {
            throw LoadError.badManifest("формат \(manifest.format)")
        }
        guard VoiceLanguage(rawValue: manifest.language) != nil else {
            throw LoadError.badManifest("язык \(manifest.language)")
        }
        guard manifest.channels == 1, manifest.sampleRate >= 8000 else {
            throw LoadError.badManifest("\(manifest.channels) кан., \(manifest.sampleRate) Гц")
        }
        var present = Set<SegmentID>()
        for (raw, entry) in manifest.segments {
            let id = SegmentID(raw)
            // Имя файла — только плоское: «../» из манифеста не выводит за пакет.
            guard id.isValidFileName, !entry.file.contains("/"),
                  FileManager.default.fileExists(atPath: directory.appendingPathComponent(entry.file).path)
            else { continue }
            present.insert(id)
        }
        return VoicePack(directory: directory, manifest: manifest, segmentIDs: present)
    }

    /// Набор для языка и выбранного голоса (28.M).
    ///
    /// Порядок: выбранный голос, целый (все отрывки сценария, sha сходятся);
    /// иначе второй голос, целый; иначе тот из двух, где уцелело больше
    /// отрывков, — битые из него вычеркнуты, и фразы с ними целиком читает
    /// синтезатор (два голоса в одной фразе не звучат никогда: набор один на
    /// всё). Ни одного настоящего набора — заглушка, если её разрешили
    /// (только отладочная сборка); иначе nil — говорит синтезатор.
    static func discover(language: VoiceLanguage, gender: VoiceGender, allowPlaceholder: Bool,
                         in root: URL? = Bundle.main.resourceURL) -> VoicePack? {
        guard let root else { return nil }
        let inventory = Set(VoiceScript.inventory(language))
        var damaged: [VoicePack] = []
        for candidate in [gender, gender.other] {
            guard let pack = loadReal(language: language, gender: candidate, root: root) else { continue }
            let corrupt = pack.corruptSegments()
            if !corrupt.isEmpty {
                Log.alerts.error("набор голоса \(candidate.rawValue, privacy: .public): битых отрывков \(corrupt.count, privacy: .public)")
            }
            let usable = pack.excluding(corrupt)
            if usable.isComplete(inventory) { return usable }
            if !usable.segmentIDs.isEmpty { damaged.append(usable) }
        }
        if let best = damaged.max(by: { $0.segmentIDs.count < $1.segmentIDs.count }) { return best }
        #if DEBUG
        if allowPlaceholder {
            let directory = root.appendingPathComponent(placeholderDirectoryName(language))
            if FileManager.default.fileExists(atPath: directory.path) {
                do {
                    let pack = try load(from: directory)
                    if pack.language == language { return pack }
                } catch {
                    Log.alerts.error("заглушка голоса не прочитана: \(String(describing: error), privacy: .public)")
                }
            }
        }
        #endif
        return nil
    }

    /// Какие голоса языка есть в сборке (для настройки «Голос»): папка на
    /// месте и манифест читается. Целостность проверяет `discover`.
    static func availableGenders(language: VoiceLanguage, in root: URL? = Bundle.main.resourceURL) -> Set<VoiceGender> {
        guard let root else { return [] }
        return Set(VoiceGender.allCases.filter { loadReal(language: language, gender: $0, root: root) != nil })
    }

    /// Настоящий набор голоса: читается, язык тот, не заглушка.
    private static func loadReal(language: VoiceLanguage, gender: VoiceGender, root: URL) -> VoicePack? {
        let name = directoryName(language, gender: gender)
        let directory = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        do {
            var pack = try load(from: directory)
            guard pack.language == language else {
                Log.alerts.error("набор голоса \(name, privacy: .public): язык \(pack.manifest.language, privacy: .public)")
                return nil
            }
            // Заглушка под именем настоящего набора не звучит нигде.
            guard !pack.isPlaceholder else { return nil }
            pack.gender = gender
            return pack
        } catch {
            Log.alerts.error("набор голоса \(name, privacy: .public) не прочитан: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// Раскодирование отрывка: sha → AAC → float32 моно с мягкими краями.
nonisolated enum SegmentDecoder {

    enum DecodeError: Error, Equatable {
        case missing
        case shaMismatch
        case unreadable(String)
        case wrongFormat(String)
    }

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func decode(_ id: SegmentID, in pack: VoicePack) throws -> AVAudioPCMBuffer {
        guard let url = pack.url(for: id), let entry = pack.manifest.segments[id.raw] else {
            throw DecodeError.missing
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DecodeError.missing
        }
        guard sha256Hex(of: data) == entry.sha256.lowercased() else { throw DecodeError.shaMismatch }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw DecodeError.unreadable(error.localizedDescription)
        }
        let format = file.processingFormat
        guard format.channelCount == 1, format.sampleRate == pack.manifest.sampleRate else {
            throw DecodeError.wrongFormat("\(format.channelCount) кан., \(format.sampleRate) Гц")
        }
        guard file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
        else { throw DecodeError.unreadable("пустой файл") }
        do {
            try file.read(into: buffer)
        } catch {
            throw DecodeError.unreadable(error.localizedDescription)
        }
        guard buffer.frameLength > 0 else { throw DecodeError.unreadable("пустой файл") }
        fadeEdges(buffer, seconds: AppConfig.voiceFadeSeconds)
        return buffer
    }

    /// Линейный вход и выход: стык двух записей, где сигнал не в нуле, иначе
    /// щёлкает.
    static func fadeEdges(_ buffer: AVAudioPCMBuffer, seconds: Double) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        let fade = min(count / 2, Int(seconds * buffer.format.sampleRate))
        guard fade > 1 else { return }
        for i in 0..<fade {
            let gain = Float(i) / Float(fade)
            samples[i] *= gain
            samples[count - 1 - i] *= gain
        }
    }
}
