//
//  AlertPlayer.swift
//  RadarMap
//
//  Звуковой сигнал + голосовое предупреждение. Играет поверх «беззвучного» режима,
//  приглушает музыку на время оповещения (AVAudioSession .playback, режим
//  .voicePrompt + .duckOthers; подкасты — на паузу).
//
//  Фразу произносит синтезатор либо — если выбран записанный голос и в пакете
//  есть все отрывки — запись диктора (этап 16, RecordedVoice + SegmentPlayer).
//  Развилка одна: `speak(_:event:)`. Сессия, промпт-стиль, громкость и
//  очередь у обоих путей общие.
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

    /// Записанный голос: решает, звучать ли фразе записью (этап 16).
    let recorded: RecordedVoice
    /// Плеер склейки. Живёт только на `audioQueue` — как и активация сессии.
    private nonisolated let segments = SegmentPlayer()
    /// Фраза, ждущая конца текущей. Запись и синтезатор звучат по очереди,
    /// никогда хором: камера, сказанная записью поверх манёвра синтезатором,
    /// не слышна ни одна.
    private enum PendingLine {
        case synth(AVSpeechUtterance)
        case recorded(ids: [SegmentID], text: String, requested: UInt64)
    }
    private var pendingLines: [PendingLine] = []
    /// Записанная фраза звучит (или стартует).
    private var recordedPlaying = false
    /// Поколение записанной фразы: конец оборванной не трогает следующую.
    private var recordedGeneration = 0
    /// Фраз отдано синтезатору и ещё не договорено. Свой счёт, а не только
    /// `isSpeaking`: тот после `speak(_:)` может стать true не сразу, и
    /// запись успела бы вступить поверх.
    private var synthOutstanding = 0
    /// Счётчик движения очереди (фраза стартовала или договорена) — для сторожа.
    private var queueProgress = 0
    /// Когда смолкнет сирена (uptime, нс). Запись стартует за десятки
    /// миллисекунд, а не за сотни, как синтезатор, и без ожидания первое
    /// слово срочной фразы ложилось бы на первый сигнал.
    private var beepEndsAt: UInt64 = 0

    /// Тактильный движок: «дорогой» отклик (мягкий на дальнем пороге → резкий у камеры).
    private var hapticEngine: CHHapticEngine?
    private let supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    init(settings: AppSettings) {
        self.settings = settings
        recorded = RecordedVoice(settings: settings, language: Self.speaksUzbek ? .uz : .ru)
        super.init()
        synthesizer.delegate = self
        // Пакет прочитан — прогреваем декодер AAC вне главного потока: первое
        // раскодирование в процессе стоит десятки миллисекунд, и платить их
        // должен не первый алерт.
        recorded.onPackLoaded = { [weak self] pack in
            guard let self, let first = pack.segmentIDs.sorted().first else { return }
            let segments = self.segments
            Self.audioQueue.async { segments.warm(first, pack: pack) }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-voiceDemo") { self.playVoiceDemo() }
            #endif
        }
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
            engine.resetHandler = { [weak engine] in
                do {
                    try engine?.start()
                } catch {
                    // Не страшно: haptic(level:) ещё раз запустит движок перед узором.
                    Log.alerts.notice("тактильный движок не поднялся после сброса: \(error.localizedDescription, privacy: .public)")
                }
            }
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
            beepEndsAt = DispatchTime.now().uptimeNanoseconds
                + UInt64(player.duration * Double(loops + 1) * 1e9)
        }
    }

    /// Подсказку не играем: Siri слушает водителя (promptStyle = none).
    private func stayQuiet(_ what: VoicePrompt.Kind) {
        Log.alerts.notice("подсказка (\(what.rawValue, privacy: .public)) промолчала: система просит тишины")
        deactivateSoon()
    }

    func speak(_ text: String) {
        speak(text, event: nil)
    }

    /// Единственная развилка «запись диктора или синтезатор» (этап 16). Места
    /// вызова, очередь и момент фразы — прежние; меняется только то, чем она
    /// произносится. `event` — фраза типом (камера, манёвр, пробка…); без
    /// него запись ищет фразу по тексту среди готовых. Не нашлось, нет
    /// отрывка, не тот голос в настройке — синтезатор, как до этапа 16.
    func speak(_ text: String, event: VoiceEvent?) {
        if let ids = recorded.plan(text: text, event: event) {
            speakRecorded(ids, text: text)
        } else {
            speakSynthesized(text)
        }
    }

    private func speakSynthesized(_ text: String) {
        // Метка на весь метод, а не только на сам speak: подбор голоса ниже —
        // это поход к речевому демону, и первый в процессе стоит сотни
        // миллисекунд ровно на главном потоке.
        MainWork.note(MainWork.Name.voice)
        defer { MainWork.note(MainWork.idle) }
        let utterance = makeUtterance(text)
        withActiveSession { [weak self] mode in
            guard let self else { return }
            switch mode {
            case .speech:
                self.startSynth(utterance)
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

    private func makeUtterance(_ text: String) -> AVSpeechUtterance {
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
        return utterance
    }

    /// Запись диктора: та же сессия и тот же промпт-стиль, что у синтезатора.
    private func speakRecorded(_ ids: [SegmentID], text: String) {
        let requested = DispatchTime.now().uptimeNanoseconds
        withActiveSession { [weak self] mode in
            guard let self else { return }
            switch mode {
            case .speech:
                self.enqueue(.recorded(ids: ids, text: text, requested: requested))
            case .tone:
                // Звонок — короткий тон вместо фразы, ровно как у синтезатора.
                preparePlayerIfNeeded()
                playBeep(loops: 0)
            case .silent:
                stayQuiet(.voice)
            }
        }
    }

    // MARK: - Очередь фраз

    /// Синтезатору — сразу, если записи нет ни звучащей, ни ждущей: тогда
    /// всё как до этапа 16, синтезатор сам ставит фразы друг за другом.
    private func startSynth(_ utterance: AVSpeechUtterance) {
        if !recordedPlaying, pendingLines.isEmpty {
            sayWithSynth(utterance)
        } else {
            pendingLines.append(.synth(utterance))
            watchQueue()
        }
    }

    private func sayWithSynth(_ utterance: AVSpeechUtterance) {
        synthOutstanding += 1
        MainWork.during(MainWork.Name.voice) { synthesizer.speak(utterance) }
    }

    private var synthBusy: Bool { synthOutstanding > 0 || synthesizer.isSpeaking }

    private func enqueue(_ line: PendingLine) {
        if recordedPlaying || synthBusy || !pendingLines.isEmpty {
            // Ждавшая фраза меряет задержку от своей очереди, а не от
            // просьбы: ожидание чужой фразы — не задержка звука.
            if case .recorded(let ids, let text, _) = line {
                pendingLines.append(.recorded(ids: ids, text: text, requested: 0))
                watchQueue()
                return
            }
            pendingLines.append(line)
            watchQueue()
        } else {
            start(line)
        }
    }

    private func start(_ line: PendingLine) {
        queueProgress += 1
        switch line {
        case .synth(let utterance):
            sayWithSynth(utterance)
        case .recorded(let ids, let text, let requested):
            playRecorded(ids, text: text, requested: requested)
        }
    }

    /// Следующие фразы, когда текущая договорена. Синтезаторные уходят в его
    /// очередь подряд; записанная ждёт, пока синтезатор замолчит.
    private func drainPending() {
        while let next = pendingLines.first, !recordedPlaying {
            if case .recorded = next, synthBusy { return }
            pendingLines.removeFirst()
            start(next)
        }
    }

    /// Сторож очереди: голова ждёт дольше разумного — что-то не позвало
    /// «договорил». Молчание о камере хуже наложения, поэтому очередь
    /// двигается дальше, а журнал называет, кто застрял.
    private func watchQueue() {
        let progress = queueProgress
        DispatchQueue.main.asyncAfter(deadline: .now() + AppConfig.voiceQueueStallSeconds) { [weak self] in
            guard let self, !self.pendingLines.isEmpty, self.queueProgress == progress else { return }
            Log.alerts.error("очередь голоса стоит \(AppConfig.voiceQueueStallSeconds, privacy: .public) с (запись \(self.recordedPlaying, privacy: .public), синтезатор \(self.synthOutstanding, privacy: .public)) — двигаю")
            self.recordedPlaying = false
            self.recordedGeneration += 1
            self.synthOutstanding = 0
            self.drainPending()
        }
    }

    private func playRecorded(_ ids: [SegmentID], text: String, requested: UInt64) {
        guard let pack = recorded.pack else { return sayWithSynth(makeUtterance(text)) }
        let requested = requested == 0 ? DispatchTime.now().uptimeNanoseconds : requested
        recordedPlaying = true
        recordedGeneration += 1
        let generation = recordedGeneration
        let volume = Float(settings.alertVolume)
        let segments = self.segments
        let now = DispatchTime.now().uptimeNanoseconds
        let waitBeep = beepEndsAt > now ? beepEndsAt - now : 0
        Self.audioQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(waitBeep))) { [weak self] in
            let outcome: Result<SegmentPlayer.Started, any Error>
            do {
                outcome = .success(try segments.play(ids, pack: pack, volume: volume) {
                    Task { @MainActor [weak self] in self?.recordedFinished(generation) }
                })
            } catch {
                outcome = .failure(error)
            }
            let started = DispatchTime.now().uptimeNanoseconds
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch outcome {
                case .success(let info):
                    // Ожидание сирены — намеренное, в задержку не входит.
                    self.noteRecordedStart(info, ids: ids,
                                           waitedMs: max(0, Double(started) - Double(requested) - Double(waitBeep)) / 1e6,
                                           generation: generation)
                case .failure(let error):
                    // Нет отрывка, sha не сошёлся, не раскодировался, движок не
                    // встал — фраза целиком синтезатором, первой в очереди.
                    Log.alerts.error("записанный голос не сыграл: \(String(describing: error), privacy: .public) — фраза синтезатором")
                    guard generation == self.recordedGeneration, self.recordedPlaying else { return }
                    self.recordedPlaying = false
                    self.sayWithSynth(self.makeUtterance(text))
                    self.drainPending()
                }
            }
        }
    }

    /// Замер до первого звука и сторож конца фразы.
    private func noteRecordedStart(_ info: SegmentPlayer.Started, ids: [SegmentID],
                                   waitedMs: Double, generation: Int) {
        let firstSoundMs = waitedMs + info.outputLatencyMs
        if firstSoundMs > AppConfig.voiceFirstSoundBudgetMs {
            Log.alerts.notice("записанный голос: до первого звука \(Int(firstSoundMs), privacy: .public) мс (склейка \(info.prepareMs, format: .fixed(precision: 1), privacy: .public), старт \(info.startMs, format: .fixed(precision: 1), privacy: .public)) — дольше бюджета")
        } else {
            Log.alerts.debug("записанный голос: \(ids.count, privacy: .public) отрывков, до первого звука \(Int(firstSoundMs), privacy: .public) мс (склейка \(info.prepareMs, format: .fixed(precision: 1), privacy: .public), старт \(info.startMs, format: .fixed(precision: 1), privacy: .public))")
        }
        // Движок, остановленный прерыванием посреди фразы, конца не позовёт.
        DispatchQueue.main.asyncAfter(deadline: .now() + info.duration + AppConfig.voiceStallGraceSeconds) { [weak self] in
            guard let self, self.recordedPlaying, self.recordedGeneration == generation else { return }
            Log.alerts.error("записанный голос: конец фразы не пришёл — очередь дальше")
            self.recordedFinished(generation)
        }
    }

    private func recordedFinished(_ generation: Int) {
        guard generation == recordedGeneration, recordedPlaying else { return }
        queueProgress += 1
        recordedPlaying = false
        drainPending()
        deactivateSoon()
    }

    #if DEBUG
    /// Отладка (`-voiceDemo` вместе с `-voicePlaceholder`, язык uz): сразу
    /// после чтения пакета — фразы записью и одна с улицей синтезатором
    /// вслед за записью. Склейка, очередь «запись → синтезатор» и задержка
    /// до первого звука видны в журнале без поездки.
    private func playVoiceDemo() {
        let events: [VoiceEvent] = [
            .camera(.init(kind: .stationaryRadar, form: .full(.aheadRight), meters: 500,
                          tail: .speedAndLimit(speed: 85, limit: 60))),
            .maneuver(.init(action: .turnRight, meters: 300, lanes: .leftTwo)),
            .phrase(.reportAccepted),
        ]
        // С паузами: каждая фраза стартует из покоя (сессия отпущена, движок
        // стоит) — так замер «до первого звука» тот же, что у алерта в пути.
        for (index, event) in events.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3 + 10 * Double(index)) { [weak self] in
                self?.speak(VoiceText.render(event), event: event)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.speak(VoiceText.render(.phrase(.reportAccepted)), event: .phrase(.reportAccepted))
            self?.speak(VoiceText.render(.phrase(.thanks)) + " Amir Temur")
        }
    }
    #endif

    /// Замолчать СЕЙЧАС: оборвать фразу и сигнал на полуслове. Выключенный звук
    /// гасит только следующие оповещения, а водитель, нажавший «без звука» у
    /// камеры, хочет тишины немедленно, а не после конца фразы.
    func hush() {
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop()
        pendingLines.removeAll()
        synthOutstanding = 0
        if recordedPlaying {
            recordedPlaying = false
            recordedGeneration += 1
            let segments = self.segments
            Self.audioQueue.async { segments.stop() }
        }
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
            // Не активировалась — звучим как раньше, фразой: promptStyle
            // неактивной сессии ничего не говорит, а молчание о камере хуже.
            var mode = VoicePrompt.Mode.speech
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
                mode = VoicePrompt.mode(for: session.promptStyle)
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
            let chosen = mode
            Task { @MainActor in then(chosen) }
        }
    }

    private func deactivateSoon() {
        // Отпускаем сессию, если ничего больше не играет (возвращаем громкость музыке).
        DispatchQueue.main.asyncAfter(deadline: .now() + AppConfig.audioReleaseDelaySeconds) { [weak self] in
            guard let self else { return }
            let stillPlaying = (self.player?.isPlaying ?? false) || self.synthesizer.isSpeaking
                || self.recordedPlaying || !self.pendingLines.isEmpty
            if !stillPlaying {
                // Ошибка деактивации не мешает работе — музыка просто чуть позже
                // вернёт громкость. Тоже вне main: деактивация — те же переговоры.
                // Движок записи гасим раньше сессии: с живым выводом она не
                // деактивируется.
                let segments = self.segments
                Self.audioQueue.async {
                    segments.idle()
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
        Task { @MainActor in self.synthDone() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.synthDone() }
    }

    /// Синтезатор договорил (или его оборвали): ждущая запись — следующая.
    private func synthDone() {
        queueProgress += 1
        synthOutstanding = synthesizer.isSpeaking ? max(0, synthOutstanding - 1) : 0
        drainPending()
        deactivateSoon()
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
