//
//  RouteCameraDirection.swift
//  RadarMap
//
//  Доказанно встречная камера маршрута — не «наша» (27.J, 22.10, владелец:
//  «убрать доказанно встречные»).
//
//  Шаг 1 гейтов — «маршрут сильнее геометрии»: камера коридора маршрута
//  (camerasAlong, 90 м) — наша без условий. Коридор не знает направления, и
//  на разделённой улице в него попадает и камера встречной проезжей части.
//  У пары-близнеца (Нурафшон: 2364 dir 238 рядом с 2369/2370 dir 58) стороны
//  поделены доказанно, и встречная 2364 стояла на 20 м раньше нашей — HUD,
//  голос и баннер говорили о ней, а не о радаре, который нас снимает.
//
//  Теперь такая камера — не маршрутная: решают обычные гейты по живому
//  фиксу (направление, ось, проезжая часть, коридор), как для любой камеры
//  вне маршрута. «Доказанно» — всё сразу:
//    • стороны дороги поделены доказанно (Camera.allowsDirectionGate:
//      близнец или неразделённая дорога, профилю доверена тишина);
//    • направление её проезжей части против курса ЛИНИИ маршрута у её точки
//      больше `cameraDirectionMaxAngle` — против КАЖДОГО курса: у вершины
//      (поворот у камеры) — и подъездного отрезка, и выездного;
//    • курс линии надёжен: отрезки не короче `routeHeadingReliableMeters`
//      (огрызки OSRM на перекрёстке дают случайный азимут) — нет надёжного
//      курса, нет и доказательства.
//  Всё недоказанное — как раньше: одиночная камера разделённой дороги без
//  близнеца (2371) может снимать обе стороны — она наша по маршруту.
//
//  Решение принимается раз на построение (camerasAlong, вне главного
//  потока) и едет флагом на RouteCamera.
//
//  Чистая логика; RouteCameraDirectionTests, LocationGatesTests.
//

import CoreLocation
import MapKit

nonisolated enum RouteCameraDirection {

    /// Курс линии у точки проекции: отрезок под ней, а у вершины (ближе
    /// `cameraOnLineVertexMeters`) — и соседний. Отрезки короче `minLength`
    /// курса не дают.
    static func headings(points: [MKMapPoint], segment: Int, t: Double,
                         minLength: CLLocationDistance = 0.5) -> [Double] {
        guard segment >= 0, segment + 1 < points.count else { return [] }
        func heading(_ index: Int) -> Double? {
            guard index >= 0, index + 1 < points.count,
                  points[index].distance(to: points[index + 1]) > minLength else { return nil }
            return GeoMath.bearing(from: points[index].coordinate, to: points[index + 1].coordinate)
        }
        var out: [Double] = []
        let length = points[segment].distance(to: points[segment + 1])
        if let own = heading(segment) { out.append(own) }
        if t * length <= AppConfig.cameraOnLineVertexMeters {
            if let before = heading(segment - 1) { out.append(before) } else if segment > 0 { return [] }
        }
        if (1 - t) * length <= AppConfig.cameraOnLineVertexMeters {
            if let after = heading(segment + 1) { out.append(after) } else if segment + 2 < points.count { return [] }
        }
        return out
    }

    /// Камера доказанно встречная для линии с этими курсами у её точки.
    /// Пусто (курса нет или он ненадёжен) — доказательства нет.
    static func isProvenOncoming(_ camera: Camera, headings: [Double]) -> Bool {
        guard camera.allowsDirectionGate, let direction = camera.dir, !headings.isEmpty else { return false }
        return headings.allSatisfy {
            GeoMath.angleDifference($0, Double(direction)) > AppConfig.cameraDirectionMaxAngle
        }
    }

    /// Всё вместе для камеры маршрута: курс линии с надёжных отрезков.
    static func isProvenOncoming(_ camera: Camera, on points: [MKMapPoint], segment: Int, t: Double) -> Bool {
        isProvenOncoming(camera, headings: headings(points: points, segment: segment, t: t,
                                                    minLength: AppConfig.routeHeadingReliableMeters))
    }
}
