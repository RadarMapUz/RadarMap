//
//  AlertPlayer.swift
//  RadarMap
//
//  Звуковой сигнал + голосовое предупреждение. Играет поверх «беззвучного» режима,
//  приглушает музыку на время оповещения (AVAudioSession .playback, режим
//  .voicePrompt + .duckOthers; подкасты — на паузу).
//

import Foundation
import AVFoundation
import CoreHaptics
import UIKit
import os

@MainActor
final class AlertPlayer: NSObject {

    /// Снос — БЕЗ прыжка на актор, и это не стиль, а обход живого бага рантайма.
    ///
    /// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor синтезирует isolated deinit
    /// каждому @MainActor-классу, даже когда своего deinit нет. Такой deinit
    /// уходит в swift_task_deinitOnExecutor, тот в синхронном кадре главного
    /// потока (текущей Task нет) заводит TaskLocal::StopLookupScope, а
    /// MarkerItem::create в рантайме iOS 26 берёт память у task-аллокатора
    /// БЕЗУСЛОВНО — при task == nullptr это статический слэб внутри
    /// libswift_Concurrency. Item::destroy потом зовёт free() по этому
    /// указателю: «pointer being freed was not allocated» → SIGABRT.
    ///
    /// Условия сходятся ровно там, где SwiftUI сносит вью с @State-моделью
    /// внутри GraphHost.runTransaction: там жива task-local привязка. В ветке
    /// main рантайма баг уже исправлен; до выхода такой iOS помогает одно —
    /// не синтезировать isolated deinit вовсе.
    nonisolated deinit {}
    private var player: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()
    private let settings: AppSettings

    /// Тактильный движок: «дорогой» отклик (мягкий на дальнем пороге → резкий у камеры).
    private var hapticEngine: CHHapticEngine?
    private let supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        synthesizer.delegate = self
        // Предзагрузка: сигнал должен звучать мгновенно, без чтения файла в
        // момент оповещения. Но не в init: AppEnvironment строится до первого
        // кадра (и на каждом фоновом пробуждении), а чтение файла с
        // prepareToPlay и запуск тактильного движка стоили запуску десятки
        // миллисекунд (аудит 11.10). Следующий оборот главного цикла наступает
        // задолго до первого фикса, а beep на всякий случай готовит сам.
        Task { @MainActor [weak self] in self?.preparePlayerIfNeeded() }
        prepareHaptics()
        // Прогрев кэша голосов ВНЕ главного потока: первое перечисление
        // speechVoices() стоит сотни миллисекунд XPC, и без прогрева их платил
        // бы первый алерт — прямо в момент фразы, замораживая спидометр.
        // static let потокобезопасен (семантика dispatch_once).
        Task.detached(priority: .utility) { _ = UzbekSpeech.nativeVoice }
    }

    // MARK: - Хаптика по уровням приближения

    private func preparePlayerIfNeeded() {
        guard player == nil,
              let url = Bundle.main.url(forResource: "alert", withExtension: "wav") else { return }
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.prepareToPlay()
        } catch {
            Log.alerts.error("alert.wav не загрузился: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func prepareHaptics() {
        guard supportsHaptics else { return }
        do {
            let engine = try CHHapticEngine()
            engine.isAutoShutdownEnabled = true   // сам гаснет в простое — экономит батарею
            // Движок могут сбросить/остановить (звонок, фон) — поднимаем обратно.
            engine.resetHandler = { [weak engine] in try? engine?.start() }
            engine.stoppedHandler = { _ in }
            // Без start(): haptic(level:) запускает движок сам перед каждым
            // узором. Запуск здесь стоил запуску времени, а при фоновом
            // пробуждении (геозона) бросал ошибку — движок обнулялся, и весь
            // процесс до выгрузки жил на запасном системном отклике.
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
        MainWork.note(MainWork.Name.haptic)
        defer { MainWork.note(MainWork.idle) }
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
        preparePlayerIfNeeded()
        guard player != nil else { return }
        let loops = max(1, count) - 1
        withActiveSession { [weak self] mode in
            guard let self else { return }
            // Тон — уже короткая подсказка: молчит он только пока Siri слушает.
            guard mode != .silent else { return self.stayQuiet(.beep) }
            self.playBeep(loops: loops)
        }
    }

    private func playBeep(loops: Int) {
        let volume = Float(settings.alertVolume)
        MainWork.during(MainWork.Name.beep) {
            guard let player else { return }
            player.stop()
            player.volume = volume
            player.numberOfLoops = loops
            player.currentTime = 0
            player.play()
        }
    }

    /// Подсказку не играем: Siri слушает водителя (promptStyle = none).
    private func stayQuiet(_ what: VoicePrompt.Kind) {
        Log.alerts.notice("подсказка (\(what.rawValue, privacy: .public)) промолчала: система просит тишины")
        deactivateSoon()
    }

    func speak(_ text: String) {
        // Метка на весь метод, а не только на сам speak: подбор голоса ниже —
        // это поход к речевому демону, и первый в процессе стоит сотни
        // миллисекунд ровно на главном потоке.
        MainWork.note(MainWork.Name.voice)
        defer { MainWork.note(MainWork.idle) }
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
        withActiveSession { [weak self] mode in
            guard let self else { return }
            switch mode {
            case .speech:
                MainWork.during(MainWork.Name.voice) { self.synthesizer.speak(utterance) }
            case .tone:
                // Идёт звонок (или Siri не пишет): Apple просит короткую
                // неречевую подсказку — фраза о камере в ухо поверх
                // разговора мешает обоим (Руководство CarPlay, стр. 53).
                preparePlayerIfNeeded()
                playBeep(loops: 0)
            case .silent:
                stayQuiet(.voice)
            }
        }
    }

    /// Замолчать СЕЙЧАС: оборвать фразу и сигнал на полуслове. Выключенный звук
    /// гасит только следующие оповещения, а водитель, нажавший «без звука» у
    /// камеры, хочет тишины немедленно, а не после конца фразы.
    func hush() {
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop()
        deactivateSoon()
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

    /// Очередь аудиосессии. НЕ главный поток: setActive над маршрутом CarPlay —
    /// это переговоры с головным устройством, Apple прямо рекомендует фоновую
    /// очередь, и в машине вызов может висеть секундами. На главном он
    /// замораживал спидометр и кнопки экрана машины ровно в момент сигнала —
    /// то есть тогда, когда водителю нужнее всего живой экран.
    private nonisolated static let audioQueue =
        DispatchQueue(label: "uz.radarmap.audio-session", qos: .userInitiated)

    /// Активировать сессию в фоне и выполнить `then` на главном акторе.
    /// Задержка старта звука на хоп очереди — миллисекунды; блокировка main на
    /// переговоры с магнитолой — секунды. Обмен в пользу живого экрана.
    /// `then` получает, КАК звучать сейчас: `promptStyle` читается уже у
    /// активной сессии и тоже вне main (VoicePrompt).
    private func withActiveSession(_ then: @escaping @MainActor (VoicePrompt.Mode) -> Void) {
        Self.audioQueue.async {
            let started = Date()
            let session = AVAudioSession.sharedInstance()
            do {
                // Режим голосовой подсказки навигатора (`.voicePrompt`): так
                // Apple велит звучать навигации. В машине CarPlay ведёт такой
                // звук как подсказку навигатора — поверх музыки и рядом с
                // голосом Яндекса, если он ведёт маршрут, — а подкаст или
                // аудиокнига встают на паузу на время фразы, а не звучат
                // одновременно с ней (`.interruptSpokenAudioAndMixWithOthers`).
                // Музыка, как и раньше, приглушается (`.duckOthers`).
                try session.setCategory(.playback, mode: .voicePrompt,
                                        options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
                try session.setActive(true)
            } catch {
                // Сигнал всё равно попробуем сыграть — хуже не станет.
                Log.alerts.error("аудиосессия не активировалась: \(error.localizedDescription, privacy: .public)")
            }
            // Замер вслух: если в машине активация действительно долгая, это
            // будет видно в логе поездки цифрой, а не гаданием.
            let elapsed = Date().timeIntervalSince(started)
            if elapsed > 0.25 {
                Log.alerts.notice("активация аудиосессии: \(elapsed, format: .fixed(precision: 2), privacy: .public) с")
            }
            let mode = VoicePrompt.mode(for: session.promptStyle)
            Task { @MainActor in then(mode) }
        }
    }

    private func deactivateSoon() {
        // Отпускаем сессию, если ничего больше не играет (возвращаем громкость музыке).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            let stillPlaying = (self.player?.isPlaying ?? false) || self.synthesizer.isSpeaking
            if !stillPlaying {
                // Ошибка деактивации не мешает работе — музыка просто чуть позже
                // вернёт громкость. Тоже вне main: деактивация — те же переговоры.
                Self.audioQueue.async {
                    try? AVAudioSession.sharedInstance()
                        .setActive(false, options: .notifyOthersOnDeactivation)
                }
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

/// Как звучать подсказке прямо сейчас — по `AVAudioSession.promptStyle`.
///
/// До 18.10 приложение его не читало, и фраза «Камера, 300 метров» звучала
/// поверх телефонного разговора в машине (аудит CarPlay 18.10, п. 7). Apple:
/// `none` — Siri слушает водителя, подсказки не играть; `short` — звонок,
/// голосовая почта или Siri, которая не пишет: короткий неречевой сигнал;
/// `normal` — обычная фраза. Чистая логика — покрыто VoicePromptTests.
nonisolated enum VoicePrompt {

    enum Mode: Equatable, Sendable {
        case speech, tone, silent
    }

    /// Что промолчало — для журнала.
    enum Kind: String, Sendable {
        case beep = "сигнал"
        case voice = "фраза"
    }

    static func mode(for style: AVAudioSession.PromptStyle) -> Mode {
        switch style {
        case .none:   return .silent
        case .short:  return .tone
        case .normal: return .speech
        @unknown default: return .speech
        }
    }
}
