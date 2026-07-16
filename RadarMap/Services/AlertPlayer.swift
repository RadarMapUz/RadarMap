//
//  AlertPlayer.swift
//  RadarMap
//
//  Звуковой сигнал + голосовое предупреждение. Играет поверх «беззвучного» режима,
//  приглушает музыку на время оповещения (AVAudioSession .playback + .duckOthers).
//

import Foundation
import AVFoundation
import os

@MainActor
final class AlertPlayer: NSObject {
    private var player: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()
    private let session = AVAudioSession.sharedInstance()
    private let settings: AppSettings

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
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ru-RU")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = Float(settings.alertVolume)
        utterance.postUtteranceDelay = 0.1
        synthesizer.speak(utterance)
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
