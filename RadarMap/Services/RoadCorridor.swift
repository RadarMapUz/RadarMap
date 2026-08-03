//
//  RoadCorridor.swift
//  RadarMap
//
//  «Наша ли это дорога» — геометрический фильтр камер перед оповещением.
//
//  Прежний фильтр был чисто угловым (±70° от курса), а угол на дистанции
//  превращается в метры: на 400 м конус принимает камеру в 375 м вбок
//  (400·sin70°). В такой конус попадают
//  камеры с параллельных улиц, дублёров, эстакад и перпендикулярных
//  перекрёстков — водитель слышит предупреждение о камере, которую не проезжает,
//  и через неделю выключает голос совсем.
//
//  Здесь вектор «мы → камера» раскладывается на продольную (вдоль курса) и
//  поперечную составляющие, и решает именно боковое отклонение. Вблизи коридор
//  узкий: курс достоверен, а кривизна дороги не успевает набежать. Дальше
//  ближней зоны он расширяется малым конусом — дорога впереди может повернуть,
//  и камера на своём же шоссе не должна выпадать. Обратная сторона расширения
//  полезна: по мере приближения допуск сужается, и камера с параллельной улицы
//  сама выпадает из коридора до того, как эскалация дойдёт до крика.
//
//  Чистая геометрия без состояния и без CLLocationManager — покрыта тестами
//  (RoadCorridorTests).
//

import CoreLocation

nonisolated struct RoadCorridor {

    /// Камера в системе координат движения.
    struct Fix: Equatable {
        /// Вдоль курса: > 0 — впереди, < 0 — уже позади.
        let along: CLLocationDistance
        /// Поперёк курса, всегда ≥ 0 — то самое «на другой улице».
        let across: CLLocationDistance
    }

    /// Разложить смещение до камеры по курсу движения.
    static func fix(from coordinate: CLLocationCoordinate2D,
                    course: CLLocationDegrees,
                    to camera: CLLocationCoordinate2D) -> Fix {
        let distance = GeoMath.fastDistance(coordinate.latitude, coordinate.longitude,
                                            camera.latitude, camera.longitude)
        let bearing = GeoMath.bearing(from: coordinate, to: camera)
        let delta = (bearing - course) * .pi / 180
        return Fix(along: distance * cos(delta), across: abs(distance * sin(delta)))
    }

    /// Допуск бокового отклонения на заданном удалении.
    /// `nearWidth` — ширина ближней зоны: если про дорогу камеры известны полосы
    /// и класс, берём её оттуда (жилая улица — 7 м, четырёхполосный проспект —
    /// 22 м) вместо одной константы на весь город.
    static func allowedAcross(along: CLLocationDistance,
                              context: AlertPolicy.Context,
                              nearWidth: CLLocationDistance? = nil) -> CLLocationDistance {
        let base = nearWidth ?? (context == .highway
            ? AppConfig.corridorHighwayMeters
            : AppConfig.corridorCityMeters)
        let ahead = max(0, along)
        guard ahead > AppConfig.corridorNearFieldMeters else { return base }
        return base + (ahead - AppConfig.corridorNearFieldMeters) * AppConfig.corridorFarSlope
    }

    /// Камера лежит на нашей дороге впереди?
    static func contains(_ fix: Fix, context: AlertPolicy.Context,
                         nearWidth: CLLocationDistance? = nil) -> Bool {
        guard fix.along >= -AppConfig.corridorBehindToleranceMeters else { return false }
        return fix.across <= allowedAcross(along: fix.along, context: context,
                                           nearWidth: nearWidth)
    }

    /// Полная проверка одной камеры от точки и курса — то, что вызывает LocationService.
    static func contains(camera: CLLocationCoordinate2D,
                         from coordinate: CLLocationCoordinate2D,
                         course: CLLocationDegrees,
                         context: AlertPolicy.Context,
                         nearWidth: CLLocationDistance? = nil) -> Bool {
        contains(fix(from: coordinate, course: course, to: camera), context: context,
                 nearWidth: nearWidth)
    }
}
