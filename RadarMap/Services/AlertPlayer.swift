//
//  AlertPlayer.swift
//  RadarMap
//
//  Звуковой сигнал + голосовое предупреждение. Играет поверх «беззвучного» режима,
//  приглушает музыку на время оповещения (AVAudioSession .playback + .duckOthers).
//

import Foundation
import AVFoundation
import CoreHaptics
import UIKit
import os

@MainActor
final class AlertPlayer: NSObject {
    private var player: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()
    private let session = AVAudioSession.sharedInstance()
    private let settings: AppSettings

    /// Тактильный движок: «дорогой» отклик (мягкий на дальнем пороге → резкий у камеры).
    private var hapticEngine: CHHapticEngine?
    private let supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        synthesizer.delegate = self
        // Предзагрузка: сигнал должен звучать мгновенно, без чтения файла в момент оповещения.
        if let url = Bundle.main.url(forResource: "alert", withExtension: "wav") {
            do {
                player = try AVAudioPlayer(contentsOf: url)
                player?.delegate = self
                player?.prepareToPlay()
            } catch {
                Log.alerts.error("alert.wav не загрузился: \(error.localizedDescription, privacy: .public)")
            }
        }
        prepareHaptics()
        // Прогрев кэша голосов ВНЕ главного потока: первое перечисление
        // speechVoices() стоит сотни миллисекунд XPC, и без прогрева их платил
        // бы первый алерт — прямо в момент фразы, замораживая спидометр.
        // static let потокобезопасен (семантика dispatch_once).
        Task.detached(priority: .utility) { _ = UzbekSpeech.nativeVoice }
    }

    // MARK: - Хаптика по уровням приближения

    private func prepareHaptics() {
        guard supportsHaptics else { return }
        do {
            let engine = try CHHapticEngine()
            engine.isAutoShutdownEnabled = true   // сам гаснет в простое — экономит батарею
            // Движок могут сбросить/остановить (звонок, фон) — поднимаем обратно.
            engine.resetHandler = { [weak engine] in try? engine?.start() }
            engine.stoppedHandler = { _ in }
            try engine.start()
            hapticEngine = engine
        } catch {
            Log.alerts.error("CHHapticEngine не запустился: \(error.localizedDescription, privacy: .public)")
            hapticEngine = nil
        }
    }

    /// Тактильный сигнал для уровня приближения: 1 — дальний порог (мягко),
    /// 2 — средний (чётче), 3 — вплотную (резкий тройной). На симуляторе и
    /// старом железе — откат на системный генератор.
    func haptic(level: Int) {
        guard settings.hapticsEnabled else { return }
        guard supportsHaptics, let engine = hapticEngine else {
            hapticFallback(level: level)
            return
        }
        do {
            try engine.start()   // мог авто-выключиться в простое
            let player = try engine.makePlayer(with: hapticPattern(for: level))
            try player.start(atTime: 0)
        } catch {
            hapticFallback(level: level)
        }
    }

    private func hapticPattern(for level: Int) throws -> CHHapticPattern {
        func tap(_ time: TimeInterval, _ intensity: Float, _ sharpness: Float) -> CHHapticEvent {
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ], relativeTime: time)
        }
        switch max(1, min(3, level)) {
        case 1:  // дальний порог — один мягкий «тук»
            return try CHHapticPattern(events: [tap(0, 0.5, 0.35)], parameters: [])
        case 2:  // средний — двойной, чётче
            return try CHHapticPattern(events: [tap(0, 0.75, 0.6), tap(0.14, 0.75, 0.6)],
                                       parameters: [])
        default: // вплотную — резкий тройной «стук»
            return try CHHapticPattern(events: [tap(0, 1.0, 0.9), tap(0.11, 1.0, 0.9),
                                                tap(0.22, 1.0, 0.95)], parameters: [])
        }
    }

    private func hapticFallback(level: Int) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(level >= 2 ? .error : .warning)
    }

    /// `count` коротких сигналов подряд (эскалация: чем ближе, тем больше).
    func beep(count: Int) {
        guard let player else { return }
        activate()
        player.stop()
        player.volume = Float(settings.alertVolume)
        player.numberOfLoops = max(1, count) - 1
        player.currentTime = 0
        player.play()
    }

    func speak(_ text: String) {
        activate()
        // Настоящий узбекский голос — если он в системе есть — читает узбекский
        // текст КАК ЕСТЬ. Переписывать орфографию под турецкую фонетику в этом
        // случае нельзя: она чинит чужой голос и ломает свой.
        // Оба голоса — из кэшей: походы к речевому демону на пути фразы стоили
        // главному потоку сотен миллисекунд на каждое оповещение.
        let useNative = Self.speaksUzbek && UzbekSpeech.nativeVoice != nil
        let spoken = (Self.speaksUzbek && !useNative) ? UzbekSpeech.spoken(text) : text
        let utterance = AVSpeechUtterance(string: spoken)
        utterance.voice = useNative ? UzbekSpeech.nativeVoice
                                    : Self.voice(for: Self.voiceLanguage)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = Float(settings.alertVolume)
        utterance.postUtteranceDelay = 0.1
        synthesizer.speak(utterance)
    }

    /// Кэш голоса по языку: AVSpeechSynthesisVoice(language:) — тоже поход к
    /// речевому демону, а язык меняется только сменой языка приложения.
    private static var voiceCache: [String: AVSpeechSynthesisVoice] = [:]
    private static func voice(for language: String) -> AVSpeechSynthesisVoice? {
        if let cached = voiceCache[language] { return cached }
        let voice = AVSpeechSynthesisVoice(language: language)
        if let voice { voiceCache[language] = voice }
        return voice
    }

    /// Интерфейс сейчас на узбекском — значит и фразы приходят узбекские.
    /// Читаем язык у самого приложения, а не у настройки: `AppLanguage.system`
    /// означает «как в системе», и знать это может только Bundle.
    static var speaksUzbek: Bool {
        (Bundle.main.preferredLocalizations.first ?? "ru").hasPrefix("uz")
    }

    /// Язык голоса.
    ///
    /// Узбекского голоса в iOS НЕТ — ни встроенного, ни догружаемого: узбекский
    /// не входит в список языков синтеза Apple вовсе. Из тюркских в системе
    /// только турецкий, и он же ближайший родственник. Поэтому узбекские фразы
    /// читает он, а орфография предварительно переписывается под турецкую
    /// фонетику (см. UzbekSpeech).
    ///
    /// Раньше здесь стояло жёсткое "ru-RU", и при узбекском интерфейсе русский
    /// синтезатор читал латиницу — за рулём это шум, а не речь.
    static var voiceLanguage: String {
        speaksUzbek ? UzbekSpeech.voiceLanguage : "ru-RU"
    }

    // MARK: - Сессия

    private func activate() {
        do {
            try session.setCategory(.playback, options: [.duckOthers, .mixWithOthers])
            try session.setActive(true)
        } catch {
            // Сигнал всё равно попробуем сыграть — хуже не станет.
            Log.alerts.error("аудиосессия не активировалась: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deactivateSoon() {
        // Отпускаем сессию, если ничего больше не играет (возвращаем громкость музыке).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            let stillPlaying = (self.player?.isPlaying ?? false) || self.synthesizer.isSpeaking
            if !stillPlaying {
                // Ошибка деактивации не мешает работе — музыка просто чуть позже вернёт громкость.
                try? self.session.setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }
}

extension AlertPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.deactivateSoon() }
    }
}

extension AlertPlayer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.deactivateSoon() }
    }
}
