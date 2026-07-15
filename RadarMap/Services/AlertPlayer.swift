//
//  AlertPlayer.swift
//  RadarMap
//
//  Звуковой сигнал + голосовое предупреждение. Играет поверх «беззвучного» режима,
//  приглушает музыку на время оповещения (AVAudioSession .playback + .duckOthers).
//

import Foundation
import AVFoundation

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
            player = try? AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.prepareToPlay()
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
        try? session.setCategory(.playback, options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true)
    }

    private func deactivateSoon() {
        // Отпускаем сессию, если ничего больше не играет (возвращаем громкость музыке).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            let stillPlaying = (self.player?.isPlaying ?? false) || self.synthesizer.isSpeaking
            if !stillPlaying {
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
