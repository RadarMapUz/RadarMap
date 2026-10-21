//
//  VoicePack.swift
//  RadarMap
//
//  Пакет записанного голоса (этап 16.3): папка `voice-<язык>.bundle` в
//  приложении — `manifest.json` и по файлу AAC на отрывок.
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

    var isPlaceholder: Bool { manifest.placeholder }
    var language: VoiceLanguage? { VoiceLanguage(rawValue: manifest.language) }

    func url(for id: SegmentID) -> URL? {
        guard let entry = manifest.segments[id.raw] else { return nil }
        return directory.appendingPathComponent(entry.file)
    }

    func duration(of ids: [SegmentID]) -> Double {
        ids.reduce(0) { $0 + (manifest.segments[$1.raw]?.duration ?? 0) }
    }

    /// Имя папки пакета в бандле.
    static func directoryName(_ language: VoiceLanguage, placeholder: Bool) -> String {
        placeholder ? "voice-\(language.rawValue)-placeholder.bundle" : "voice-\(language.rawValue).bundle"
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

    /// Пакет для языка: настоящий, а без него — заглушка, если её разрешили
    /// (только отладочная сборка). nil — пакета нет, говорит синтезатор.
    static func discover(language: VoiceLanguage, allowPlaceholder: Bool,
                         in root: URL? = Bundle.main.resourceURL) -> VoicePack? {
        guard let root else { return nil }
        var candidates = [directoryName(language, placeholder: false)]
        #if DEBUG
        if allowPlaceholder { candidates.append(directoryName(language, placeholder: true)) }
        #endif
        for name in candidates {
            let directory = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            do {
                let pack = try load(from: directory)
                guard pack.language == language else {
                    Log.alerts.error("пакет голоса \(name, privacy: .public): язык \(pack.manifest.language, privacy: .public)")
                    continue
                }
                #if !DEBUG
                // Заглушка в выпуске не звучит ни под каким именем.
                if pack.isPlaceholder { continue }
                #endif
                if pack.isPlaceholder, !allowPlaceholder { continue }
                return pack
            } catch {
                Log.alerts.error("пакет голоса \(name, privacy: .public) не прочитан: \(String(describing: error), privacy: .public)")
            }
        }
        return nil
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
