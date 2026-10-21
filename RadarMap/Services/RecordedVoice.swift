//
//  RecordedVoice.swift
//  RadarMap
//
//  Записанный голос: ЧЕМ звучать фразе — записью диктора или синтезатором
//  (этап 16.3–16.4).
//
//  Решение принимается до звука и без звука: выбран ли записанный голос,
//  есть ли пакет, описана ли фраза событием, говорит ли событие ровно то,
//  что написано, и есть ли в пакете КАЖДЫЙ нужный отрывок. Любое «нет» —
//  фраза целиком идёт синтезатором, как шла до этапа 16. Молчания не бывает,
//  половины фразы записью — тоже.
//
//  Порядок, громкость, промпт-стиль и аудиосессия остаются у AlertPlayer:
//  запись лишь заменяет то, чем фраза произносится.
//

import Foundation
import os
import Observation

/// Чей голос читает фразы.
enum VoiceSource: String, CaseIterable, Identifiable {
    case system, recorded
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:   return String(localized: "Системный голос")
        case .recorded: return String(localized: "Записанный голос")
        }
    }

    /// Что звучит на деле. Пакета нет — системный, что бы ни было выбрано
    /// (выбор при этом сохраняется). Пакет есть, а человек не выбирал —
    /// записанный: ради него пакет и везут.
    nonisolated static func effective(choice: VoiceSource?, packAvailable: Bool) -> VoiceSource {
        guard packAvailable else { return .system }
        return choice ?? .recorded
    }
}

/// Чистая часть решения — покрыта RecordedVoiceTests.
nonisolated enum RecordedVoicePlan {

    /// Почему фраза пошла синтезатором — для журнала и тестов.
    enum Fallback: Error, Equatable {
        /// Событие говорит не то, что написано.
        case textMismatch
        /// Событие не собирается записью (значение вне ступеней) или в пакете
        /// нет хотя бы одного отрывка.
        case missingSegments
    }

    /// Отрывки фразы или причина, по которой её прочтёт синтезатор.
    /// `rendered` — текст события (VoiceText.render) для сверки с `text`.
    static func decide(text: String, event: VoiceEvent, rendered: String, language: VoiceLanguage,
                       available: Set<SegmentID>) -> Result<[SegmentID], Fallback> {
        guard rendered == text else { return .failure(.textMismatch) }
        guard let ids = segments(for: event, language: language, available: available) else {
            return .failure(.missingSegments)
        }
        return .success(ids)
    }

    /// Отрывки фразы или nil, если хоть одного нет в пакете.
    static func segments(for event: VoiceEvent, language: VoiceLanguage,
                         available: Set<SegmentID>) -> [SegmentID]? {
        guard let ids = VoiceComposer.segments(for: event, in: language),
              ids.contains(where: { !$0.isPause }),
              ids.allSatisfy({ $0.isPause || available.contains($0) }) else { return nil }
        return ids
    }
}

@MainActor
@Observable
final class RecordedVoice {

    /// Снос — без прыжка на актор (см. AlertPlayer: обход бага рантайма iOS 26).
    nonisolated deinit {}

    /// Пакет языка приложения; nil — нет (или ещё читается).
    private(set) var pack: VoicePack?
    let language: VoiceLanguage

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var textIndex: [String: VoiceEvent]?
    @ObservationIgnored private var loadGeneration = 0
    /// Пакет прочитан — AlertPlayer прогревает декодер.
    @ObservationIgnored var onPackLoaded: ((VoicePack) -> Void)?

    init(settings: AppSettings, language: VoiceLanguage) {
        self.settings = settings
        self.language = language
        reload()
    }

    /// Пакет есть — настройку «Голос» стоит показывать.
    var isAvailable: Bool { pack != nil }

    /// Звучит ли сейчас запись (выбор человека + наличие пакета).
    var isActive: Bool {
        VoiceSource.effective(choice: settings.voiceSourceChoice, packAvailable: pack != nil) == .recorded
    }

    /// Перечитать пакет (запуск и отладочный переключатель заглушки). Чтение
    /// манифеста и проверка файлов — вне главного потока.
    func reload() {
        loadGeneration += 1
        let generation = loadGeneration
        let language = language
        let allowPlaceholder = settings.placeholderVoiceAllowed
        // Низкий приоритет: пакет нужен к первой фразе, а не к первому кадру.
        Task(priority: .utility) { [weak self] in
            let pack = await Self.discover(language: language, allowPlaceholder: allowPlaceholder)
            guard let self, generation == self.loadGeneration else { return }
            self.pack = pack
            if let pack {
                // Указатель фраз по тексту — сейчас, а не на первом алерте.
                _ = self.index
                self.onPackLoaded?(pack)
                Log.alerts.notice("записанный голос: \(pack.manifest.language, privacy: .public), \(pack.segmentIDs.count, privacy: .public) отрывков\(pack.isPlaceholder ? " (заглушка)" : "", privacy: .public)")
            }
        }
    }

    /// Чтение манифеста и проверка ~150 файлов — вне главного потока.
    @concurrent
    private nonisolated static func discover(language: VoiceLanguage,
                                             allowPlaceholder: Bool) async -> VoicePack? {
        VoicePack.discover(language: language, allowPlaceholder: allowPlaceholder)
    }

    /// Отрывки фразы — или nil, и тогда её читает синтезатор.
    ///
    /// `event` — от того, кто строил фразу; без него фраза ищется по тексту
    /// среди фраз с конечным набором слов (`VoiceText.index`).
    func plan(text: String, event: VoiceEvent?) -> [SegmentID]? {
        guard isActive, let pack else { return nil }
        guard let event = event ?? index[text] else { return nil }
        // Сверка: запись обязана сказать ровно то, что написано. Разошлись —
        // значит кто-то поправил фразу и не поправил событие; говорит
        // синтезатор, а журнал называет обе стороны.
        let rendered = VoiceText.render(event)
        switch RecordedVoicePlan.decide(text: text, event: event, rendered: rendered,
                                        language: language, available: pack.segmentIDs) {
        case .success(let ids):
            return ids
        case .failure(.textMismatch):
            Log.alerts.error("записанный голос: событие «\(rendered, privacy: .public)» ≠ фраза «\(text, privacy: .public)» — синтезатор")
            return nil
        case .failure(.missingSegments):
            Log.alerts.notice("записанный голос: для «\(text, privacy: .public)» нет отрывков — синтезатор")
            return nil
        }
    }

    private var index: [String: VoiceEvent] {
        if let textIndex { return textIndex }
        let built = VoiceText.index()
        textIndex = built
        return built
    }
}
