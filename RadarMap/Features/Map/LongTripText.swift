//
//  LongTripText.swift
//  RadarMap
//
//  Подписи листа «Перед дальней дорогой» (12.4) — отдельно от вида, чтобы
//  склонения и фразы проверялись тестом (LongTripTextTests).
//

import CoreLocation
import Foundation

enum LongTripText {

    // MARK: - Километр пути

    /// Километр от старта: дальше 10 км — целым («47 км», а не «47,0 км»: это
    /// столб у дороги, а не замер), ближе — как везде в приложении.
    static func km(_ meters: CLLocationDistance) -> String {
        guard meters >= 10_000 else { return Formatting.distance(max(0, meters)) }
        return Formatting.unbreakable(String(format: String(localized: "%@ км"),
                                             String(Int((meters / 1000).rounded()))))
    }

    // MARK: - Сводка

    /// «18 камер · 2 поста ДПС · 1 отметка водителей»; пустые части молчат.
    static func tally(_ tally: LongTripBrief.Tally) -> String {
        var parts: [String] = []
        if tally.cameras > 0 { parts.append("\(tally.cameras)\u{00A0}" + Formatting.camerasLabel(tally.cameras)) }
        if tally.posts > 0 { parts.append("\(tally.posts)\u{00A0}" + postsLabel(tally.posts)) }
        if tally.crowd > 0 { parts.append("\(tally.crowd)\u{00A0}" + crowdLabel(tally.crowd)) }
        return parts.joined(separator: " · ")
    }

    /// Каталог не печатает число в этих строках (как `camerasLabel`): форма
    /// по `PluralRu`, в узбекском все три — одно слово.
    static func postsLabel(_ count: Int) -> String {
        switch PluralRu.form(count) {
        case .one:  String(localized: "пост ДПС")
        case .few:  String(localized: "поста ДПС")
        case .many: String(localized: "постов ДПС")
        }
    }

    static func crowdLabel(_ count: Int) -> String {
        switch PluralRu.form(count) {
        case .one:  String(localized: "отметка водителей")
        case .few:  String(localized: "отметки водителей")
        case .many: String(localized: "отметок водителей")
        }
    }

    // MARK: - Камеры и посты

    /// «Пост ДПС», «Пост ДПС · ещё 2 камеры».
    static func title(_ checkpoint: LongTripBrief.Checkpoint) -> String {
        let kind = checkpoint.lead.kind.displayName
        guard checkpoint.others > 0 else { return kind }
        let others = "\(checkpoint.others)\u{00A0}" + Formatting.camerasLabel(checkpoint.others)
        return kind + " · " + String(format: String(localized: "ещё %@"), others)
    }

    /// Голосом VoiceOver: «47 километров от старта, пост ДПС, ещё 2 камеры, М39».
    static func spoken(_ checkpoint: LongTripBrief.Checkpoint, locale: Locale = NumberFormat.locale) -> String {
        var parts = [String(format: String(localized: "%@ от старта"),
                            SpokenUnits.distance(checkpoint.along, locale: locale)),
                     title(checkpoint)]
        let place = checkpoint.lead.displayTitle
        if !place.isEmpty { parts.append(place) }
        return parts.joined(separator: ", ")
    }

    // MARK: - Заправки

    static func fuelHeader(_ kind: Venue.Kind) -> String {
        switch kind {
        case .cng:      return String(localized: "Метан по пути")
        case .lpg:      return String(localized: "Пропан по пути")
        case .charging: return String(localized: "Зарядки по пути")
        default:        return String(localized: "Заправки по пути")
        }
    }

    /// «Дольше всего без метана — 112 км».
    static func gapTitle(_ kind: Venue.Kind, meters: CLLocationDistance) -> String {
        let distance = Formatting.distance(meters)
        switch kind {
        case .cng:      return String(format: String(localized: "Дольше всего без метана — %@"), distance)
        case .lpg:      return String(format: String(localized: "Дольше всего без пропана — %@"), distance)
        case .charging: return String(format: String(localized: "Дольше всего без зарядки — %@"), distance)
        default:        return String(format: String(localized: "Дольше всего без заправки — %@"), distance)
        }
    }

    /// Где этот отрезок: от старта, до конца пути или между двумя километрами.
    static func gapDetail(_ gap: LongTripBrief.Gap, progress: CLLocationDistance,
                          routeLength: CLLocationDistance) -> String {
        // Метр туда-сюда — тот же старт: прогресс и линия считаются раздельно.
        let fromStart = gap.from <= progress + 1
        let toFinish = gap.to >= routeLength - 1
        switch (fromStart, toFinish) {
        case (true, true):
            return String(localized: "весь путь")
        case (true, false):
            return String(format: String(localized: "от старта до %@"), km(gap.to))
        case (false, true):
            return String(format: String(localized: "от %@ до конца пути"), km(gap.from))
        case (false, false):
            return String(format: String(localized: "от %1$@ до %2$@ от старта"),
                          km(gap.from), km(gap.to))
        }
    }

    /// Своего топлива по пути нет вовсе — совет, а не только факт.
    static func none(_ kind: Venue.Kind) -> String {
        switch kind {
        case .cng:      return String(localized: "Метана по пути не нашлось — заправьтесь до выезда")
        case .lpg:      return String(localized: "Пропана по пути не нашлось — заправьтесь до выезда")
        case .charging: return String(localized: "Зарядок по пути не нашлось — зарядитесь до выезда")
        default:        return String(localized: "Заправок по пути не нашлось — заправьтесь до выезда")
        }
    }

    /// «Метан · 1,2 км от дороги» — вид пишется, только если у заведения
    /// своё имя (иначе вид уже стоит заголовком).
    static func venueDetail(_ item: CorridorVenues.Item) -> String {
        let place = item.offset <= AppConfig.corridorVenueRoadsideMeters
            ? String(localized: "у дороги")
            : String(format: String(localized: "%@ от дороги"), Formatting.distance(item.offset))
        return item.venue.name.isEmpty ? place : AlongRouteText.title(item.venue.kind) + " · " + place
    }

    /// «47 километров от старта, заправка метан, Metan Chinoz, у дороги».
    static func spoken(_ item: CorridorVenues.Item, locale: Locale = NumberFormat.locale) -> String {
        var parts = [String(format: String(localized: "%@ от старта"), SpokenUnits.distance(item.along, locale: locale)),
                     AlongRouteText.spokenKind(item.venue.kind)]
        if !item.venue.name.isEmpty { parts.append(item.venue.name) }
        parts.append(item.offset <= AppConfig.corridorVenueRoadsideMeters
                     ? String(localized: "у дороги")
                     : String(format: String(localized: "%@ от дороги"),
                              SpokenUnits.distance(item.offset, locale: locale)))
        return parts.joined(separator: ", ")
    }
}
