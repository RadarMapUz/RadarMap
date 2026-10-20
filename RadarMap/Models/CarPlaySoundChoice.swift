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
//  Голосовой режим, выбранный в машине, — настройка, как в «Настройках»: он
//  остаётся. Тишина — нет (спит пассажир, идёт разговор — это про поездку).
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

    /// Голосовой режим выбора; у тишины его ставит сама тишина (с запоминанием
    /// прежнего — `CarPlaySceneDelegate.toggleMute`).
    var voiceMode: VoiceMode {
        switch self {
        case .all: return .always
        case .smart: return .smart
        case .beepOnly, .silent: return .off
        }
    }

    var soundEnabled: Bool { self != .silent }

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
    var symbol: String {
        switch self {
        case .all: return "speaker.wave.3.fill"
        case .smart: return "speaker.wave.1.fill"
        case .beepOnly: return "bell.fill"
        case .silent: return "speaker.slash.fill"
        }
    }
}
