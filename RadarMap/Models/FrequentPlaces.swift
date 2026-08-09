//
//  FrequentPlaces.swift
//  RadarMap
//
//  «Дом» и «Работа», которые приложение выучивает само.
//
//  Раньше главный экран держал два пустых серых круга с плюсом: приложение
//  просило человека сделать работу, которую само знало лучше него. Машина
//  каждый вечер приезжает в одну точку и каждое утро буднего дня уезжает в
//  другую — это и есть дом с работой, и ничего вводить для этого не нужно.
//
//  Данные — только те, что уже лежат на диске (TripRecord): финиш поездки и
//  её время. Ни одного нового поля, ни байта наружу, всё считается локально.
//
//  Классификация опирается на РАСПОРЯДОК, а не на частоту:
//    дом    — куда приезжают вечером и откуда уезжают утром;
//    работа — куда приезжают утром буднего дня и откуда уезжают под вечер.
//  Частота одна ничего не значит: заправка у дома посещается чаще работы.
//
//  Уверенность считается в РАЗНЫХ ДНЯХ, а не в визитах: шесть заездов за одну
//  субботу — это не привычка, а один день. Пока разных дней меньше трёх,
//  места нет вовсе: ошибиться с «домом» хуже, чем промолчать.
//
//  Чистая логика, покрыта FrequentPlacesTests.
//

import CoreLocation
import Foundation

nonisolated enum FrequentPlaces {

    enum Kind: String, Equatable {
        case home, work

        var title: String {
            switch self {
            case .home: return String(localized: "Дом")
            case .work: return String(localized: "Работа")
            }
        }

        /// Фраза предложения — «куда», а не «что»: на кнопке читается действие.
        var suggestionTitle: String {
            switch self {
            case .home: return String(localized: "Домой")
            case .work: return String(localized: "На работу")
            }
        }

        var symbol: String {
            switch self {
            case .home: return "house.fill"
            case .work: return "briefcase.fill"
            }
        }
    }

    /// Выученное место.
    struct Place: Equatable, Identifiable {
        var kind: Kind
        var lat: Double
        var lon: Double
        /// Сколько РАЗНЫХ дней подтверждают место.
        var days: Int

        var id: String { kind.rawValue }
        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    // MARK: - Обучение

    /// Что выучили по истории поездок. Пустой массив — данных пока мало.
    ///
    /// `now` параметром, а не `Date()` внутри: расчёт обязан быть
    /// воспроизводимым в тестах — то же правило, что у PeriodSummary.
    static func learn(history: [TripRecord], now: Date,
                      calendar: Calendar = .current,
                      windowDays: Int = AppConfig.placeLearningWindowDays,
                      minDays: Int = AppConfig.placeMinDistinctDays) -> [Place] {
        let since = now.addingTimeInterval(-Double(windowDays) * 86400)
        var clusters: [Cluster] = []

        for record in history where record.endedAt >= since {
            // Приезд есть всегда: конечная точка хранится в самой записи.
            if let end = record.endCoordinate {
                add(Visit(coordinate: end, date: record.endedAt, isArrival: true),
                    to: &clusters)
            }
            // Отъезд знаем только пока жив трек (его вырезают через неделю) —
            // это добавочный сигнал, а не обязательный: дом опознаётся и по
            // одним вечерним приездам.
            if let start = record.trackPoints.first {
                add(Visit(coordinate: CLLocationCoordinate2D(latitude: start.lat,
                                                             longitude: start.lon),
                          date: record.startedAt, isArrival: false),
                    to: &clusters)
            }
        }

        let scored = clusters.map { Scored($0, calendar: calendar) }
        var result: [Place] = []

        // Дом — сильнейший ночной кластер. Он же исключается из кандидатов на
        // работу: утренний отъезд из дома и утренний приезд на работу выглядят
        // одинаково, и без этого дом побеждал бы в обеих номинациях.
        let home = scored
            .filter { $0.homeScore > 0 && $0.days >= minDays }
            .max { $0.homeScore < $1.homeScore }
        if let home {
            result.append(Place(kind: .home, lat: home.cluster.lat,
                                lon: home.cluster.lon, days: home.days))
        }
        let work = scored
            .filter { $0.cluster.id != home?.cluster.id }
            .filter { $0.workScore > 0 && $0.workDays >= minDays }
            .max { $0.workScore < $1.workScore }
        if let work {
            result.append(Place(kind: .work, lat: work.cluster.lat,
                                lon: work.cluster.lon, days: work.workDays))
        }
        return result
    }

    // MARK: - Предложение «куда поедем»

    /// Что предложить прямо сейчас: nil — предлагать нечего, и строки на
    /// экране быть не должно.
    ///
    /// Правило простое и не пытается угадывать сверх очевидного: стоя дома
    /// утром буднего дня человек едет на работу, стоя на работе — домой,
    /// вечером в любой точке города — домой. Место, в котором мы уже стоим,
    /// не предлагается никогда: это единственная гарантированно бесполезная
    /// подсказка.
    static func suggestion(places: [Place],
                           from coordinate: CLLocationCoordinate2D?,
                           now: Date,
                           calendar: Calendar = .current,
                           atRadius: CLLocationDistance = AppConfig.placeAtRadiusMeters) -> Place? {
        guard let coordinate else { return nil }
        let home = places.first { $0.kind == .home }
        let work = places.first { $0.kind == .work }
        let hour = calendar.component(.hour, from: now)
        let weekday = calendar.component(.weekday, from: now)
        let isWeekend = weekday == 1 || weekday == 7
        let morning = hour >= 5 && hour < 12
        let evening = hour >= 16 || hour < 5

        func isAt(_ place: Place?) -> Bool {
            guard let place else { return false }
            return GeoMath.fastDistance(coordinate.latitude, coordinate.longitude,
                                        place.lat, place.lon) <= atRadius
        }

        if isAt(home) {
            // Из дома утром буднего дня — на работу. В выходной и вечером
            // человек дома не потому, что собрался ехать.
            return (morning && !isWeekend) ? work : nil
        }
        if isAt(work) { return home }
        if evening { return home }
        return (morning && !isWeekend) ? work : nil
    }

    // MARK: - Внутреннее

    private struct Visit {
        let coordinate: CLLocationCoordinate2D
        let date: Date
        let isArrival: Bool
    }

    /// Кластер визитов: центр — среднее, чтобы точка не прыгала за последним
    /// парковочным местом.
    private struct Cluster {
        let id: Int
        var lat: Double
        var lon: Double
        var visits: [Visit] = []

        mutating func append(_ visit: Visit) {
            visits.append(visit)
            let n = Double(visits.count)
            lat += (visit.coordinate.latitude - lat) / n
            lon += (visit.coordinate.longitude - lon) / n
        }
    }

    private static func add(_ visit: Visit, to clusters: inout [Cluster],
                            radius: CLLocationDistance = AppConfig.placeClusterMeters) {
        for index in clusters.indices {
            let distance = GeoMath.fastDistance(visit.coordinate.latitude,
                                                visit.coordinate.longitude,
                                                clusters[index].lat, clusters[index].lon)
            if distance <= radius {
                clusters[index].append(visit)
                return
            }
        }
        var fresh = Cluster(id: clusters.count,
                            lat: visit.coordinate.latitude,
                            lon: visit.coordinate.longitude)
        fresh.append(visit)
        clusters.append(fresh)
    }

    /// Оценки кластера по распорядку.
    private struct Scored {
        let cluster: Cluster
        /// Разных дней всего и разных БУДНИХ дней (знаменатель для работы).
        let days: Int
        let workDays: Int
        let homeScore: Int
        let workScore: Int

        init(_ cluster: Cluster, calendar: Calendar) {
            self.cluster = cluster
            var allDays: Set<Date> = []
            var weekdayDays: Set<Date> = []
            var home = 0
            var work = 0
            for visit in cluster.visits {
                let day = calendar.startOfDay(for: visit.date)
                allDays.insert(day)
                let hour = calendar.component(.hour, from: visit.date)
                let weekday = calendar.component(.weekday, from: visit.date)
                let isWeekend = weekday == 1 || weekday == 7
                if visit.isArrival {
                    // Приехал вечером/ночью — здесь ночуют.
                    if hour >= 18 || hour < 5 { home += 1 }
                    // Приехал утром буднего дня — сюда ездят работать.
                    if !isWeekend, hour >= 6, hour < 12 {
                        work += 1
                        weekdayDays.insert(day)
                    }
                } else {
                    // Уехал утром — отсюда выезжают на день.
                    if hour >= 5 && hour < 11 { home += 1 }
                    // Уехал под вечер буднего дня — отсюда возвращаются.
                    if !isWeekend, hour >= 14, hour < 22 {
                        work += 1
                        weekdayDays.insert(day)
                    }
                }
            }
            days = allDays.count
            workDays = weekdayDays.count
            homeScore = home
            workScore = work
        }
    }
}
