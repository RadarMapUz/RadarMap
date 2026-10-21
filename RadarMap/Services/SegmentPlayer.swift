//
//  SegmentPlayer.swift
//  RadarMap
//
//  Плеер склейки записанного голоса (этап 16.3): отрывки встык, одним
//  буфером, через AVAudioEngine.
//
//  Почему один буфер, а не очередь буферов: склейка в памяти — это
//  копирование сотни тысяч сэмплов (доли миллисекунды), зато стык точен до
//  сэмпла, конец фразы — один обработчик, а между словами не может
//  втиснуться ничего постороннего. Края каждого отрывка смягчены
//  (SegmentDecoder.fadeEdges), паузы на месте запятых — настоящая тишина
//  нужной длины.
//
//  Живёт ТОЛЬКО на очереди аудиосессии AlertPlayer: старт движка — те же
//  переговоры с аудиосервером (и с магнитолой в CarPlay), что и активация
//  сессии, и на главном потоке они замораживали бы спидометр ровно в момент
//  фразы (ARCHITECTURE.md, правило 21).
//

import AVFoundation
import Foundation
import os

nonisolated final class SegmentPlayer: @unchecked Sendable {

    enum PlayError: Error, Equatable {
        case segment(SegmentID, SegmentDecoder.DecodeError)
        case join
        case engine(String)
    }

    /// Чем закончилась попытка: сколько заняла подготовка и старт.
    struct Started: Sendable {
        /// Раскодирование и склейка (кэш — почти ноль), мс.
        let prepareMs: Double
        /// Старт движка и постановка буфера, мс.
        let startMs: Double
        /// Длина фразы, с.
        let duration: Double
        /// Задержка вывода аудиосессии (буфер + маршрут), мс.
        let outputLatencyMs: Double
    }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var attached = false
    private var connectedFormat: AVAudioFormat?
    private var cache = SegmentCache(budgetBytes: AppConfig.voiceCacheBytes)

    /// Склеить фразу: раскодировать (или взять из кэша) отрывки и паузы.
    /// Ошибка у любого отрывка — ошибка всей фразы: полфразы не звучит.
    func prepare(_ ids: [SegmentID], pack: VoicePack) throws -> AVAudioPCMBuffer {
        // Чего нет в кэше — раскодируем разом, на всех ядрах: восемь отрывков
        // по 4–5 мс подряд — это 40 мс до первого звука, параллельно — около
        // десяти. Готовое держим и локально: кэш с потолком мог бы вытеснить
        // только что положенное раньше, чем фраза склеится.
        var fresh: [SegmentID: AVAudioPCMBuffer] = [:]
        let missing = Array(Set(ids.filter { !$0.isPause && cache[$0] == nil }))
        for (id, result) in zip(missing, Self.decodeAll(missing, pack: pack)) {
            switch result {
            case .success(let buffer):
                fresh[id] = buffer
                cache[id] = buffer
            case .failure(let error):
                throw PlayError.segment(id, error)
            }
        }
        var parts: [AVAudioPCMBuffer] = []
        for id in ids {
            if id.isPause {
                let seconds = id == .stop ? AppConfig.voicePauseStopSeconds : AppConfig.voicePauseCommaSeconds
                guard let format = parts.first?.format ?? Self.format(of: pack),
                      let silence = Self.silence(seconds: seconds, format: format) else { throw PlayError.join }
                parts.append(silence)
            } else if let buffer = fresh[id] ?? cache[id] {
                parts.append(buffer)
            } else {
                throw PlayError.segment(id, .missing)
            }
        }
        guard let joined = Self.join(parts) else { throw PlayError.join }
        return joined
    }

    /// Раскодировать несколько отрывков параллельно; порядок результатов —
    /// порядок `ids`.
    static func decodeAll(_ ids: [SegmentID],
                          pack: VoicePack) -> [Result<AVAudioPCMBuffer, SegmentDecoder.DecodeError>] {
        guard !ids.isEmpty else { return [] }
        // `nonisolated(unsafe)`: каждая итерация пишет только в свою ячейку,
        // гонок нет, а замок на каждую запись был бы лишним.
        nonisolated(unsafe) let slots = UnsafeMutableBufferPointer<Result<AVAudioPCMBuffer, SegmentDecoder.DecodeError>?>
            .allocate(capacity: ids.count)
        slots.initialize(repeating: nil)
        defer { slots.deallocate() }
        DispatchQueue.concurrentPerform(iterations: ids.count) { index in
            do {
                slots[index] = .success(try SegmentDecoder.decode(ids[index], in: pack))
            } catch let error as SegmentDecoder.DecodeError {
                slots[index] = .failure(error)
            } catch {
                slots[index] = .failure(.unreadable(String(describing: error)))
            }
        }
        return slots.map { $0 ?? .failure(.missing) }
    }

    /// Сыграть фразу. `finished` зовётся, когда последний сэмпл прозвучал
    /// (или плеер остановлен) — с внутреннего потока движка.
    func play(_ ids: [SegmentID], pack: VoicePack, volume: Float,
              finished: @escaping @Sendable () -> Void) throws -> Started {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let buffer = try prepare(ids, pack: pack)
        let t1 = DispatchTime.now().uptimeNanoseconds
        do {
            if !attached {
                engine.attach(node)
                attached = true
            }
            if connectedFormat != buffer.format {
                engine.disconnectNodeOutput(node)
                engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
                connectedFormat = buffer.format
            }
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
        } catch {
            throw PlayError.engine(error.localizedDescription)
        }
        node.volume = volume
        node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in
            finished()
        }
        node.play()
        let t2 = DispatchTime.now().uptimeNanoseconds
        let session = AVAudioSession.sharedInstance()
        return Started(prepareMs: Double(t1 - t0) / 1e6,
                       startMs: Double(t2 - t1) / 1e6,
                       duration: Double(buffer.frameLength) / buffer.format.sampleRate,
                       outputLatencyMs: (session.outputLatency + session.ioBufferDuration) * 1000)
    }

    /// Оборвать фразу на полуслове (hush). Обработчик конца при этом зовётся.
    func stop() {
        node.stop()
    }

    /// Ничего не звучит и не ждёт — гасим вывод до следующей фразы: он,
    /// работающий вхолостую, — это батарея и занятая аудиосессия. `pause`, а
    /// не `stop`: вывод останавливается так же, но подготовленные ресурсы
    /// остаются, и следующий старт короче.
    func idle() {
        guard engine.isRunning else { return }
        node.stop()
        engine.pause()
    }

    /// Прогреть кодек: первое раскодирование AAC в процессе поднимает
    /// декодер (десятки миллисекунд), и платить их должен не первый алерт.
    func warm(_ id: SegmentID, pack: VoicePack) {
        guard cache[id] == nil else { return }
        do {
            cache[id] = try SegmentDecoder.decode(id, in: pack)
        } catch {
            // Не страшно: та же ошибка всплывёт у настоящей фразы, и та уйдёт
            // синтезатору целиком. Здесь — только строка в журнал.
            Log.alerts.notice("прогрев голоса: \(id.raw, privacy: .public) — \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Чистые части

    static func format(of pack: VoicePack) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: pack.manifest.sampleRate,
                      channels: 1, interleaved: false)
    }

    static func silence(seconds: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(max(1, (seconds * format.sampleRate).rounded()))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        samples.update(repeating: 0, count: Int(frames))
        return buffer
    }

    /// Встык, сэмпл к сэмплу. nil — частей нет или форматы разные.
    static func join(_ parts: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let format = parts.first?.format,
              parts.allSatisfy({ $0.format == format }) else { return nil }
        let total = parts.reduce(0) { $0 + Int($1.frameLength) }
        guard total > 0,
              let joined = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)),
              let target = joined.floatChannelData?[0] else { return nil }
        var offset = 0
        for part in parts {
            guard let source = part.floatChannelData?[0] else { return nil }
            let count = Int(part.frameLength)
            (target + offset).update(from: source, count: count)
            offset += count
        }
        joined.frameLength = AVAudioFrameCount(total)
        return joined
    }
}

/// Кэш раскодированных отрывков с потолком в байтах: дольше всех не
/// звучавший уходит первым.
nonisolated struct SegmentCache {
    private var buffers: [SegmentID: AVAudioPCMBuffer] = [:]
    private var order: [SegmentID] = []
    private(set) var bytes = 0
    let budgetBytes: Int

    init(budgetBytes: Int) { self.budgetBytes = budgetBytes }

    var count: Int { buffers.count }

    subscript(id: SegmentID) -> AVAudioPCMBuffer? {
        mutating get {
            guard let buffer = buffers[id] else { return nil }
            touch(id)
            return buffer
        }
        set {
            if let old = buffers.removeValue(forKey: id) {
                bytes -= Self.size(of: old)
                order.removeAll { $0 == id }
            }
            guard let newValue else { return }
            buffers[id] = newValue
            order.append(id)
            bytes += Self.size(of: newValue)
            while bytes > budgetBytes, order.count > 1, let oldest = order.first {
                order.removeFirst()
                if let evicted = buffers.removeValue(forKey: oldest) { bytes -= Self.size(of: evicted) }
            }
        }
    }

    private mutating func touch(_ id: SegmentID) {
        guard let index = order.firstIndex(of: id), index != order.count - 1 else { return }
        order.remove(at: index)
        order.append(id)
    }

    static func size(of buffer: AVAudioPCMBuffer) -> Int {
        Int(buffer.frameCapacity) * Int(buffer.format.channelCount) * MemoryLayout<Float>.size
    }
}
