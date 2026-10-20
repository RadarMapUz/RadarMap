//
//  DestinationGuess.swift
//  RadarMap
//
//  «Куда едем?» — одна догадка для телефона и машины.
//
//  Решение «куда предложить» живёт в FrequentPlaces.suggestion (по
//  распорядку, а не по частоте). Здесь — то, что вокруг него: заданный рукой
//  адрес старше выученного (и делает подсказку возможной в первый же день),
//  «обычно 39 мин» — медиана своих поездок туда (Commute), без сети. Раньше
//  это было зашито во вью телефона, и машине пришлось бы повторить его — с
//  риском разойтись: в одной машине «Домой», на телефоне «На работу».
//
//  Маршрута на догадку нет и здесь: чтобы узнать время по дорогам, нужно
//  отправить на сервер дом и работу человека, которых он не просил строить.
//  Время с пробками он увидит, нажав «Поехали».
//
//  Пока своих поездок меньше трёх, «обычно» берётся у водителей (8.8.16):
//  своя линия пути, сложенная на телефоне с обычными скоростями чужих
//  поездок в этот час (TypicalTraffic) — «обычно ~35 мин (по водителям)».
//  Своё «обычно» всегда старше.
//

import CoreLocation
import Foundation

struct DestinationGuess: Equatable {
    let kind: FrequentPlaces.Kind
    let coordinate: CLLocationCoordinate2D
    /// Адрес, заданный рукой; у выученного места адреса нет — и врать о нём
    /// не надо.
    let placeTitle: String?
    /// Медиана своих поездок туда за 30 дней; nil — истории мало.
    let usual: TimeInterval?
    /// Обычное время по водителям (8.8.16) — только пока своего `usual` нет.
    var crowdUsual: TimeInterval? = nil
    /// При выезде сейчас (8.8.6): медиана на этот час по профилю пути плюс
    /// сегодняшние пробки сверх обычного. Только когда мы стоим у начала этой
    /// дороги (у дома — «на работу», у работы — «домой»): из ресторана в 15 км
    /// профиль «работа → дом» про «сейчас» не говорит ничего. nil — тогда
    /// честное «обычно» за месяц.
    var estimate: CommuteEstimate.Estimate?

    static func == (a: DestinationGuess, b: DestinationGuess) -> Bool {
        a.kind == b.kind && a.placeTitle == b.placeTitle && a.usual == b.usual && a.estimate == b.estimate
            && a.crowdUsual == b.crowdUsual
            && a.coordinate.latitude == b.coordinate.latitude
            && a.coordinate.longitude == b.coordinate.longitude
    }

    /// «сейчас ~52 мин, пробки +8 мин» — если есть оценка на этот час, иначе
    /// «обычно 39 мин», а без своей истории — «обычно ~35 мин (по водителям)».
    /// Пробки — только заметные (от 3 мин): меньше — шум, и строка не должна
    /// прыгать каждые две минуты вместе с now.json.
    var usualText: String? {
        if let estimate {
            let head = String(format: String(localized: "сейчас ~%@"),
                              Formatting.unbreakable(Formatting.duration(estimate.seconds)))
            let jam = Int((estimate.jamSeconds / 60).rounded())
            guard jam >= AppConfig.commuteJamShowMinutes else { return head }
            return head + ", " + String(localized: "пробки +\(jam) мин")
        }
        if let usual {
            return String(format: String(localized: "обычно %@"),
                          Formatting.unbreakable(Formatting.duration(usual)))
        }
        return crowdUsual.map { Self.crowdText($0) }
    }

    /// `usualText` для VoiceOver (14.6): то же решение, но словами — «сейчас
    /// около 52 минут, пробки плюс 8 минут», без тильды и «мин».
    var spokenUsualText: String? {
        if let estimate {
            let head = String(format: String(localized: "сейчас около %@"),
                              SpokenUnits.duration(estimate.seconds))
            let jam = Int((estimate.jamSeconds / 60).rounded())
            guard jam >= AppConfig.commuteJamShowMinutes else { return head }
            return head + ", " + String(format: String(localized: "пробки плюс %@"), SpokenUnits.minutes(jam))
        }
        if let usual {
            return String(format: String(localized: "обычно %@"), SpokenUnits.duration(usual))
        }
        return crowdUsual.map {
            String(format: String(localized: "обычно около %@, по данным водителей"), SpokenUnits.duration($0))
        }
    }

    /// «обычно ~35 мин (по водителям)» — источник назван: это чужие поездки,
    /// не своя история, и выдавать их за своё «обычно» нельзя.
    static func crowdText(_ seconds: TimeInterval) -> String {
        String(format: String(localized: "обычно ~%@ (по водителям)"),
               Formatting.unbreakable(Formatting.duration(seconds)))
    }

    /// Строка под заголовком: время и адрес, что есть. Время — первым: строка
    /// в одну линию, и на узком экране обрезаться должен адрес, а не «пробки +8».
    var subtitle: String {
        let parts = [usualText, placeTitle].compactMap { $0 }
        guard !parts.isEmpty else { return String(localized: "Ваш обычный маршрут") }
        let line = parts.joined(separator: " · ")
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    /// Что предложить сейчас; nil — нечего.
    /// - Parameters:
    ///   - manual: заданные рукой Дом/Работа (Настройки → Мои места).
    ///   - usual: медиана поездок по направлению (Commute), nil — нет данных.
    ///   - crowd: обычное время по водителям (8.8.16); берётся, только если
    ///     своего `usual` нет.
    static func make(learned: [FrequentPlaces.Place],
                     manual: (FrequentPlaces.Kind) -> SavedPlace?,
                     usual: (Commute.Direction) -> TimeInterval?,
                     crowd: (Commute.Direction) -> TimeInterval? = { _ in nil },
                     estimate: (Commute.Direction) -> CommuteEstimate.Estimate? = { _ in nil },
                     from coordinate: CLLocationCoordinate2D?,
                     now: Date,
                     calendar: Calendar = .current) -> DestinationGuess? {
        var places = learned
        for kind in [FrequentPlaces.Kind.home, .work] {
            guard let place = manual(kind) else { continue }
            places.removeAll { $0.kind == kind }
            places.append(FrequentPlaces.Place(kind: kind, lat: place.lat, lon: place.lon,
                                               days: AppConfig.placeMinDistinctDays))
        }
        guard let place = FrequentPlaces.suggestion(places: places, from: coordinate,
                                                    now: now, calendar: calendar) else { return nil }
        let direction: Commute.Direction = place.kind == .work ? .toWork : .toHome
        let typical = usual(direction)
        // «Сейчас» — только от начала этой дороги: у дома, если едем на работу,
        // у работы — если домой.
        let origin = places.first { $0.kind == (place.kind == .work ? .home : .work) }
        let atOrigin = zip2(coordinate, origin).map {
            GeoMath.fastDistance($0.latitude, $0.longitude, $1.lat, $1.lon)
                <= AppConfig.commuteGhostStartRadiusMeters
        } ?? false
        let forNow = atOrigin ? estimate(direction) : nil
        // Своё «обычно» старше чужого: с третьей поездки «по водителям» уходит.
        let fromCrowd = typical == nil ? crowd(direction) : nil
        if let hand = manual(place.kind) {
            return DestinationGuess(kind: place.kind, coordinate: hand.coordinate,
                                    placeTitle: hand.title, usual: typical, crowdUsual: fromCrowd,
                                    estimate: forNow)
        }
        return DestinationGuess(kind: place.kind, coordinate: place.coordinate,
                                placeTitle: nil, usual: typical, crowdUsual: fromCrowd, estimate: forNow)
    }

    private static func zip2<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
        guard let a, let b else { return nil }
        return (a, b)
    }
}
