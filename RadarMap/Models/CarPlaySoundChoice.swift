//
//  CarPlaySoundChoice.swift
//  RadarMap
//
//  Звук в машине — короткий список, а не только «выключить всё» (план 19.10,
//  10.1). Кнопка с динамиком в баре CarPlay глушила и голос, и сигналы
//  разом, а водителю на трассе с пассажиром нужна середина: «говори только
//  когда превышаю» или «только пискни». Четыре строки — те же настройки, что
//  на телефоне (`VoiceMode` + сигналы), без своего состояния:
//
//    * «Обо всех камерах» — голос о каждой (`.always`), сигналы;
//    * «Умно» — голос при превышении и о внезапных точках (`.smart`);
//    * «Только сигнал» — без голоса, сигнал остаётся (`.off`, сигналы);
//    * «Тишина до конца поездки» — ни голоса, ни сигналов; как и прежняя
//      кнопка — атрибут поездки, откатывается при выходе из машины.
//
//  Любой выбор здесь — атрибут поездки в машине, как и прежняя тишина: «Только
//  сигнал» для спящего пассажира не должен навсегда выключить голос на
//  телефоне. При выходе из машины поле возвращается к «до машины» — если с
//  тех пор его никто не трогал (ревью 20.10). Сигналы выбор голоса не
//  трогает, кроме выхода из тишины: выключенные руками на телефоне они
//  молча не включаются.
//
//  Чистая логика — CarPlaySoundChoiceTests.
//

import Foundation

enum CarPlaySoundChoice: CaseIterable, Hashable {
    case all, smart, beepOnly, silent

    /// Что выбрано сейчас — по самим настройкам, без своего хранилища:
    /// поменяли на телефоне — бар машины покажет то же.
    static func current(soundEnabled: Bool, voiceMode: VoiceMode) -> CarPlaySoundChoice {
        switch voiceMode {
        case .off: return soundEnabled ? .beepOnly : .silent
        case .smart: return .smart
        case .always: return .all
        }
    }

    /// Голосовой режим выбора.
    var voiceMode: VoiceMode {
        switch self {
        case .all: return .always
        case .smart: return .smart
        case .beepOnly, .silent: return .off
        }
    }

    var soundEnabled: Bool { self != .silent }

    /// Звук целиком: сигналы и голос.
    struct Sound: Equatable {
        var enabled: Bool
        var voice: VoiceMode
    }

    /// Что ставит выбор поверх нынешнего. Сигналы — суть «Только сигнал» и
    /// «Тишины»; голосовые режимы их не трогают, кроме выхода из тишины.
    static func applying(_ choice: CarPlaySoundChoice, to current: Sound) -> Sound {
        switch choice {
        case .silent: return Sound(enabled: false, voice: .off)
        case .beepOnly: return Sound(enabled: true, voice: .off)
        case .all, .smart:
            let wasSilent = !current.enabled && current.voice == .off
            return Sound(enabled: wasSilent || current.enabled, voice: choice.voiceMode)
        }
    }

    /// Выход из машины: поле возвращается к «до машины», только если оно
    /// всё ещё такое, каким его поставила машина, — поменянное с тех пор
    /// руками (на светофоре, в «Настройках») — осознанный выбор, его не трогаем.
    static func restoring(before: Sound, carSet: Sound, current: Sound) -> Sound {
        Sound(enabled: current.enabled == carSet.enabled ? before.enabled : current.enabled,
              voice: current.voice == carSet.voice ? before.voice : current.voice)
    }

    /// Откат звука, поставленного в машине. Зовётся при выходе из машины и при
    /// старте процесса: выгрузка или падение посреди поездки не присылают
    /// didDisconnect, и «Тишина до конца поездки» оставалась на следующую поездку —
    /// камеры молчали, пока машину не подключат и не отключат ещё раз.
    @MainActor
    static func restoreAfterCar(settings: AppSettings) {
        defer { Storage.set(false, for: .carPlayMuted) }
        guard Storage.bool(.carPlayMuted) else { return }
        let before = Sound(
            enabled: Storage.bool(.carPlaySoundBeforeMute),
            voice: Storage.string(.carPlayVoiceBeforeMute).flatMap(VoiceMode.init(rawValue:)) ?? .smart)
        // Маркер прежней тишины (до 20.10) без «поставленного» — это тишина.
        let carSet = Sound(
            enabled: Storage.bool(.carPlaySoundSet),
            voice: Storage.string(.carPlayVoiceSet).flatMap(VoiceMode.init(rawValue:)) ?? .off)
        let current = Sound(enabled: settings.soundEnabled, voice: settings.voiceMode)
        let next = restoring(before: before, carSet: carSet, current: current)
        if next.enabled != current.enabled { settings.soundEnabled = next.enabled }
        if next.voice != current.voice { settings.voiceMode = next.voice }
    }

    var title: String {
        switch self {
        case .all: return String(localized: "Обо всех камерах")
        case .smart: return String(localized: "Умно — при превышении")
        case .beepOnly: return String(localized: "Только сигнал")
        case .silent: return String(localized: "Тишина до конца поездки")
        }
    }

    /// Короткое имя — в заголовке списка («Сейчас: Умно») и в подписи бара.
    var shortTitle: String {
        switch self {
        case .all: return String(localized: "Обо всех")
        case .smart: return String(localized: "Умно")
        case .beepOnly: return String(localized: "Сигнал")
        case .silent: return String(localized: "Без звука")
        }
    }

    /// Глиф кнопки бара: по нему видно состояние не читая — промах слепого
    /// тапа не должен глушить камеры незаметно.
    /// Те же значки, что у шкалы голоса и тумблера сигнала на телефоне
    /// (VoiceMode.symbol, Icon.alertSignal): один выбор — один значок везде.
    var symbol: String {
        switch self {
        case .all, .smart, .silent: return voiceMode.symbol
        case .beepOnly: return Icon.alertSignal
        }
    }
}
