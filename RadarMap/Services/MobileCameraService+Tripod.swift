//
//  MobileCameraService+Tripod.swift
//  RadarMap
//
//  Свежесть отметок водителей и голос вопроса «ещё стоит?» (пункт 82) —
//  отдельно от основного файла сервиса.
//

import Foundation

extension MobileCameraService {

    /// Свежесть из ответа /api/mobile; времена — по часам сервера плюс поправка.
    nonisolated static func freshness(_ created: Double?, _ lastConfirmed: Double?, trust: Int?,
                                      doubted: Int?, confirmed: Bool?, skew: TimeInterval) -> TripodFreshness.Info {
        TripodFreshness.Info(
            created: created.map { Date(timeIntervalSince1970: $0 + skew) },
            lastConfirmed: lastConfirmed.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 + skew) : nil },
            trust: trust,
            doubted: doubted ?? 0,
            confirmed: confirmed ?? true)
    }

    /// Свежесть отметки по id камеры.
    func freshness(for cameraID: Int) -> TripodFreshness.Info? {
        reports.first { $0.id == cameraID }?.mobileFresh
    }

    /// Сказать вопрос голосом один раз на отметку: true — пора сказать.
    /// Голос — только там, где ответ — одно касание (карточка на экране или
    /// баннер в машине), поэтому зовут его те, кто вопрос показал.
    func claimQuestionVoice(for id: Int) -> Bool {
        guard spokenQuestionID != id else { return false }
        spokenQuestionID = id
        return true
    }
}

extension MobileCameraService.QuickOutcome {
    /// Экранный ответ, когда нажатие влилось в уже стоящую метку (82):
    /// голос остаётся записанным «Подтвердили, спасибо».
    var mergedText: String? {
        switch self {
        case .sent(.confirmed): return String(localized: "Уже отмечено — подтвердили, спасибо")
        case .sent(.mine):      return String(localized: "Уже отметили здесь")
        default:                return nil
        }
    }
}
