//
//  ItogiPreviews.swift
//  RadarMap
//
//  Превью переделанных экранов «Итогов» (аудит 05.11, вариант A) на демо-неделе
//  `-itogiDemo`: по ним снимаются «было / стало». Экраны читают окружение,
//  поэтому превью берут общий корень и засевают его той же демо-историей, что
//  и ключ запуска. Карточка-ответ без окружения — в ItogiAnswerCard.swift.
//

#if DEBUG
import SwiftUI

/// Общий корень с демо-неделей «Итогов» — один раз на процесс превью.
enum ItogiPreviewEnv {
    static let env: AppEnvironment = {
        let env = AppEnvironment.shared
        env.trip.seedItogiDemo(cleanGoal: false)
        env.mobile.seedImpactDemo()
        return env
    }()

    static var week: DateInterval { StatsPeriod.week.interval(containing: Date()) }

    static var summary: PeriodSummary {
        TripHistory.summary(days: env.trip.days, history: env.trip.history, period: .week, anchor: Date())
    }

    /// Поездка демо-недели с проездами — для детали поездки и проезда.
    static var tripWithPasses: TripRecord? {
        env.trip.history.first { !$0.passed.isEmpty } ?? env.trip.history.first
    }
}

/// SE, язык и тема — как у остальных превью проекта.
private struct ItogiScreenPreview<Content: View>: View {
    var locale = "ru"
    var scheme: ColorScheme = .light
    @ViewBuilder var content: Content

    var body: some View {
        content
            .environment(ItogiPreviewEnv.env)
            .frame(width: 375, height: 812)
            .background(Theme.background)
            .environment(\.locale, Locale(identifier: locale))
            .environment(\.colorScheme, scheme)
    }
}

#Preview("Итоги · главный лист · SE · ru · день") {
    ItogiScreenPreview { TripStatsSheet() }
}

#Preview("Итоги · главный лист · SE · uz · ночь") {
    ItogiScreenPreview(locale: "uz", scheme: .dark) { TripStatsSheet() }
}

#Preview("Итоги · рейтинг недели · SE · ru · день") {
    ItogiScreenPreview {
        RatingDetailSheet(summary: ItogiPreviewEnv.summary, period: .week,
                          interval: ItogiPreviewEnv.week, anchor: Date())
    }
}

#Preview("Итоги · рейтинг недели · SE · uz · ночь") {
    ItogiScreenPreview(locale: "uz", scheme: .dark) {
        RatingDetailSheet(summary: ItogiPreviewEnv.summary, period: .week,
                          interval: ItogiPreviewEnv.week, anchor: Date())
    }
}

#Preview("Итоги · деталь поездки · SE") {
    ItogiScreenPreview {
        if let record = ItogiPreviewEnv.tripWithPasses {
            TripDetailSheet(record: record)
        }
    }
}

#Preview("Итоги · проезд камеры · SE") {
    ItogiScreenPreview {
        if let record = ItogiPreviewEnv.tripWithPasses, let pass = record.passed.first {
            PassMapSheet(pass: pass, track: record.trackPoints, record: record)
        }
    }
}

#Preview("Итоги · штрафы · могут прийти · SE") {
    ItogiScreenPreview {
        FinesScreen(request: FinesRequest(window: .period(.week, Date()), tab: .possible,
                                          periodRisk: ItogiPreviewEnv.summary.fineRisk))
    }
}

#Preview("Итоги · пробки и скорость вне камер · SE") {
    ItogiScreenPreview {
        let env = ItogiPreviewEnv.env
        let itogi = ItogiScreen.build(days: env.trip.days, history: env.trip.history,
                                      period: .week, anchor: Date(), now: Date())
        RoadHabitSheet(payload: RoadHabitPayload(kind: .overLimit, summary: itogi.summary, jams: itogi.jams,
                                                 places: itogi.overLimitPlaces,
                                                 periodTitle: StatsPeriod.week.rangeTitle(containing: Date())))
    }
}

#Preview("Итоги · архив поездок · SE") {
    ItogiScreenPreview { AllTripsSheet() }
}

#Preview("Итог поездки · SE · ночь") {
    ItogiScreenPreview(scheme: .dark) {
        VStack {
            Spacer()
            if let record = ItogiPreviewEnv.tripWithPasses {
                TripEndCard(record: record, onDetail: { _ in }, onMerged: {}, onDismiss: {})
                    .padding(16)
            }
        }
    }
}
#endif
