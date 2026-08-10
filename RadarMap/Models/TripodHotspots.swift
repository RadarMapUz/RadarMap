//
//  TripodHotspots.swift
//  RadarMap
//
//  «Здесь часто ставят треногу» — память о местах, а не отметка о радаре.
//
//  Дислокацию передвижных радаров никто не публикует: её утверждает начальник
//  областной службы, и с 2022 года водителю не показывают её даже на месте.
//  Но точки в ней повторяются — инспектор возвращается на те же участки.
//  Сервер сводит накопленные отметки водителей в кластеры (server/
//  build_hotspots.py) и присылает подписанный список; здесь — решение, о какой
//  точке уместно сказать вслух прямо сейчас.
//
//  Правило тона здесь ОБРАТНОЕ правилу камер, и это осознанно. У камеры
//  молчание хуже лишнего сигнала, поэтому неизвестность толкует в пользу
//  предупреждения. Здесь предупреждения нет — есть догадка о прошлом. Догадка,
//  выданная за факт, стоит доверия ко всему приложению, поэтому неизвестность
//  (нет курса, нет лимита, не превышаем) означает молчание. Точка при этом
//  остаётся видимой на карте: показать — не то же самое, что сказать.
//

import Foundation
import CoreLocation

nonisolated struct TripodHotspots: Decodable, Sendable {
    struct Spot: Decodable, Sendable, Hashable {
        let lat: Double
        let lon: Double
        /// Сколько отметок собралось в этом месте за окно наблюдения.
        let n: Int
        /// В скольких РАЗНЫХ дней это было: пять отметок за один день — это
        /// одна пробка с треногой, а не привычка ставить её здесь.
        let days: Int
        /// Четверть суток, на которую приходится перевес: 0 ночь, 1 утро,
        /// 2 день, 3 вечер. −1 — перевеса нет, ставят когда угодно.
        let peak: Int

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }

        /// Ключ «уже сказали за эту поездку». Упакованные координаты, а не
        /// индекс в массиве: список обновляется еженедельно, и индекс после
        /// обновления показал бы на другое место.
        var key: Int64 {
            Int64((lat * 100_000).rounded()) << 24 ^ Int64((lon * 100_000).rounded())
        }

        /// «Обычно утром». nil — перевеса нет, и врать про время не надо.
        var peakTitle: String? {
            switch peak {
            case 0:  return String(localized: "обычно ночью")
            case 1:  return String(localized: "обычно утром")
            case 2:  return String(localized: "обычно днём")
            case 3:  return String(localized: "обычно вечером")
            default: return nil
            }
        }

        /// Подпись на карточке: чем эта точка заслужила подсказку.
        var caption: String {
            let base = String(format: String(localized: "Отмечали %lld раз, в разные дни: %lld"),
                              n, days)
            guard let peakTitle else { return base }
            return base + ", " + peakTitle
        }
    }

    let version: Int
    let spots: [Spot]

    /// Пустой список — то, чем живёт приложение при любой неисправности файла.
    static let empty = TripodHotspots(version: 1, spots: [])

    /// Данные считаем годными только с известной версией контракта: чужой
    /// формат лучше не толковать «как получится», а честно счесть пустым.
    var isUsable: Bool { version == 1 }
}

// MARK: - Решение «сказать сейчас»

nonisolated enum HotspotAlert {
    /// Всё, от чего зависит решение. Время и настройки приходят параметрами —
    /// движок обязан быть воспроизводимым в тесте.
    struct Situation {
        let coordinate: CLLocationCoordinate2D
        /// Курс движения; < 0 — недоверенный (см. LocationFilter).
        let course: CLLocationDegrees
        /// Идёт ли поездка: подсказка — часть вождения, а не просмотра карты.
        let isTripActive: Bool
        /// Превышаем ли прямо сейчас (лимит известен и он превышен).
        let isOverspeeding: Bool
        /// Подсказки включены в настройках.
        let hintsEnabled: Bool
    }

    /// Точка, о которой уместно сказать вслух. nil — молчим.
    ///
    /// Голос только при превышении, и это главное: на ежедневном маршруте
    /// подсказка при каждом проезде превратится в шум, от которого сама же
    /// перестанет работать — ровно та болезнь, от которой лечили «умную
    /// тишину». Едете в лимите — точка просто нарисована на карте.
    static func spotToAnnounce(in spots: [TripodHotspots.Spot],
                               situation: Situation,
                               alreadyVoiced: Set<Int64>,
                               within: CLLocationDistance = AppConfig.hotspotWarnMeters)
    -> TripodHotspots.Spot? {
        guard situation.hintsEnabled, situation.isTripActive,
              situation.isOverspeeding, situation.course >= 0 else { return nil }
        var best: TripodHotspots.Spot?
        var bestAlong = CLLocationDistance.greatestFiniteMagnitude
        for spot in spots where !alreadyVoiced.contains(spot.key) {
            let fix = RoadCorridor.fix(from: situation.coordinate,
                                       course: situation.course,
                                       to: spot.coordinate)
            // Позади — не наш случай: подсказка имеет смысл только до участка.
            guard fix.along > 0, fix.along <= within else { continue }
            guard RoadCorridor.contains(fix, context: .city) else { continue }
            if fix.along < bestAlong {
                best = spot
                bestAlong = fix.along
            }
        }
        return best
    }

    /// Фраза. Коротко и без числа метров: это не «камера через 300 метров»,
    /// а свойство участка, и точность здесь была бы обещанием, которого у нас
    /// нет.
    static func phrase(for spot: TripodHotspots.Spot) -> String {
        guard let peakTitle = spot.peakTitle else {
            return String(localized: "Здесь часто ставят треногу")
        }
        return String(format: String(localized: "Здесь часто ставят треногу, %@"), peakTitle)
    }
}
