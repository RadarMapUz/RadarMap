//
//  SpokenUnits.swift
//  RadarMap
//
//  Числа с единицами для VoiceOver (14.6): «35 минут», «350 метров», а не
//  «35 мин» и «350 м». На экране сокращение экономит место и читается
//  глазом за долю секунды; голосом оно звучит обрывком («тридцать пять
//  мин») или буквами, а у тильды «~35» есть своё имя, которое никто не
//  хотел услышать. Поэтому подпись VoiceOver собирается отдельно — теми же
//  числами, что на экране, но полными словами.
//
//  Формы слов («1 минута», «2 минуты», «5 минут»; uz «5 daqiqa») даёт сам
//  Foundation по локали языка приложения, а не по региону телефона — то же
//  правило, что у `NumberFormat`. Общий для приложения и виджетов.
//

import Foundation

nonisolated enum SpokenUnits {

    /// «1 час 23 минуты», «35 минут» — то же число, что `Formatting.duration`
    /// показывает на экране (минуты отбрасываются, а не округляются: иначе
    /// голос и цифра расходились бы на минуту). Меньше минуты — секундами.
    static func duration(_ seconds: Double, locale: Locale = NumberFormat.locale) -> String {
        let total = Int(max(0, seconds).rounded())
        guard total >= 60 else {
            return Duration.seconds(total)
                .formatted(.units(allowed: [.seconds], width: .wide).locale(locale))
        }
        return Duration.seconds(total / 60 * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .wide).locale(locale))
    }

    /// Ровно `minutes` минут — для подписей, которые округляют сами (виджет).
    static func minutes(_ minutes: Int, locale: Locale = NumberFormat.locale) -> String {
        Duration.seconds(max(0, minutes) * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .wide).locale(locale))
    }

    /// «350 метров», «1,4 километра», «129 километров» — то же округление,
    /// что `Formatting.distance`: метры целыми, до сотни километров — с
    /// десятой, дальше целыми.
    static func distance(_ meters: Double, locale: Locale = NumberFormat.locale) -> String {
        if meters < 1000 {
            return Measurement(value: max(0, meters).rounded(), unit: UnitLength.meters)
                .formatted(.measurement(width: .wide, usage: .asProvided).locale(locale))
        }
        let km = meters / 1000
        let digits = km < 100 ? 0...1 : 0...0
        return Measurement(value: km, unit: UnitLength.kilometers)
            .formatted(.measurement(width: .wide, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(digits)))
                .locale(locale))
    }
}
