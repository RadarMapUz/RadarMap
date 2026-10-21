//
//  CarPlayGuidancePause.swift
//  RadarMap
//
//  Пауза ведения в машине: «Перестраиваю маршрут» и «Нет сигнала GPS»
//  (25.H1).
//
//  CPNavigationSession ставит карточку манёвра на паузу с причиной
//  (`CPTripPauseReason`: arrived, loading, locating, rerouting,
//  proceedToRoute); снимает паузу следующий список манёвров. До 25.H1 у нас
//  была только пауза перестроения: при потере сигнала (тоннель, подземный
//  паркинг, Ташкент-Сити) карточка показывала «через 300 м направо» по
//  застывшей точке, а машина ехала дальше. Теперь — `.locating`, пока сторож
//  фиксов (`LocationService.isSignalStale`) говорит «нет сигнала», и снятие
//  на первом принятом фиксе.
//
//  Порядок: перестроение старше поиска сигнала — старый поворот неверен при
//  любом сигнале. Поиск сигнала — только после первого манёвра: до него
//  сессия и так стоит на «загружаю», и снять «ищу сигнал» было бы нечем.
//
//  Плашка «Нет сигнала GPS» на нашей карте (CarPlayStatusChips) при паузе
//  поиска сигнала не рисуется: о том же говорит карточка системы, две
//  одинаковые вести на одном экране — шум.
//
//  Чистая логика; CarPlayGuidancePauseTests.
//

nonisolated enum CarPlayGuidancePause {

    enum Reason: Equatable, Sendable {
        case rerouting
        case locating
    }

    enum Step: Equatable, Sendable {
        case none
        case pause(Reason)
        /// Снять паузу: отправить манёвр заново.
        case resume
    }

    /// Какая пауза нужна сейчас. `locatingEnabled` — пауза поиска сигнала
    /// доступна (план 25.H1 включает её с iOS 27).
    static func wanted(rerouting: Bool, signalStale: Bool, hasManeuver: Bool,
                       locatingEnabled: Bool) -> Reason? {
        if rerouting { return .rerouting }
        if locatingEnabled, signalStale, hasManeuver { return .locating }
        return nil
    }

    static func step(current: Reason?, wanted: Reason?) -> Step {
        guard current != wanted else { return .none }
        guard let wanted else { return .resume }
        return .pause(wanted)
    }

    /// Плашка «Нет сигнала GPS» на нашей карте.
    static func showsGPSChip(signalStale: Bool, systemLocating: Bool) -> Bool {
        signalStale && !systemLocating
    }
}
