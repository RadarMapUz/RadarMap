//
//  CameraOnLine.swift
//  RadarMap
//
//  Камера на пути — на линии маршрута, а не «на дороге рядом» (27.B, 22.10,
//  владелец: «радары валяются на дороге — можем именно в линии расположить»).
//
//  Координата камеры в базе снята на ось СВОЕЙ проезжей части (snap_cameras),
//  а линия маршрута идёт по оси OSRM — по нашей. На разделённой улице это
//  10–40 м вбок, и значок лежал на соседней проезжей части (снимок 22.10,
//  Нурафшон обводная, камера 2371). Как у Яндекса, камера на пути рисуется
//  в точке проекции на линию; подпись «400 м» у тревожной — там же.
//
//  «На пути» — тот же принцип, что у оповещений: неизвестно — показывать.
//  Камера маршрута (camerasAlong, коридор 90 м) не наша только при
//  ДОКАЗАТЕЛЬСТВЕ — тем же признакам, что у шага 2 гейтов (LocationGates):
//    • направление проезжей части против курса маршрута, и стороны дороги
//      доказанно поделены (Camera.allowsDirectionGate: пара-близнец);
//    • ось её дороги поперёк маршрута (мост, поперечная улица развязки).
//  Такая камера остаётся на своей координате и спокойной (не «на пути»):
//  до 27.B встречный близнец (2364 у 2369/2370) красился как наш — это
//  ошибка выбора, а не картинки. Одиночная камера на разделённой дороге без
//  близнеца (2371) может снимать обе стороны — она на пути и ложится на линию.
//
//  Без маршрута на пути одна камера — ближайшая наша (та же, что в HUD); её
//  переносим на ось нашей дороги (прямая через прижатую RoadSnapper точку по
//  курсу дороги), если она на этой оси: впереди, рядом сбоку и её дорога
//  идёт так же, как наша (иначе между нами кривая, и прямая врёт).
//
//  ТОЛЬКО КАРТИНКА. Гейты, проезды, голос, уровни и сама Camera — по
//  настоящей координате; перенесённая точка живёт отдельно (Display.points)
//  и не попадает ни в один сервис, кроме карты (CameraOnLineTests сверяет
//  исходники, как testPipelineNeverReadsPrediction).
//
//  Считается редко: точки маршрута — один раз на построение, вне главного
//  потока, вместе с camerasAlong (RouteService.apply); на кадре — только
//  отбор по прогрессу. PerformanceBudgetTests.
//
//  Чистая логика; CameraOnLineTests.
//

import CoreLocation
import MapKit

nonisolated enum CameraOnLine {

    /// Что маршрут знает о своей камере.
    enum Verdict: String, Equatable, Sendable {
        /// На линии: рисуется в точке проекции.
        case onLine
        /// Наша по маршруту, но линия дальше `cameraOnLineMaxMeters` —
        /// остаётся на своей координате (цвет «на пути» сохраняется).
        case beside
        /// Доказано не наша (встречная при поделённых сторонах, поперечная) —
        /// своя координата и спокойный облик.
        case notOurs
    }

    /// Точка для показа. Равенство — с допуском в полметра: проекция на ту же
    /// прямую из соседних точек отличается в последних битах, а каждое
    /// «изменение» переписывало бы весь источник камер.
    struct Point: Equatable, Sendable {
        let latitude: Double
        let longitude: Double

        init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }

        init(_ coordinate: CLLocationCoordinate2D) {
            self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
        }

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }

        static func == (lhs: Point, rhs: Point) -> Bool {
            abs(lhs.latitude - rhs.latitude) < 5e-6 && abs(lhs.longitude - rhs.longitude) < 5e-6
        }
    }

    /// Камера маршрута: точка на линии и вердикт.
    struct Spot: Equatable, Sendable {
        let point: Point
        let verdict: Verdict
    }

    /// Что рисовать: камеры на пути (цвет типа) и камеры не на своей
    /// координате (id → точка на линии).
    struct Display: Equatable, Sendable {
        var pathIDs: Set<Int> = []
        var points: [Int: Point] = [:]

        static let empty = Display()

        /// Где рисовать камеру: на линии или там, где она стоит.
        func coordinate(of camera: Camera) -> CLLocationCoordinate2D {
            points[camera.id]?.coordinate ?? camera.coordinate
        }
    }

    // MARK: - Маршрут (раз на построение)

    /// Точки камер маршрута на его линии. `along` — метры от старта, которые
    /// уже нашёл `RouteService.camerasAlong` (ближайшая точка ломаной), и
    /// кумулятив здесь той же меры (`MKMapPoint.distance`), так что точка —
    /// ровно его проекция: O(n) на маршрут и O(log n) на камеру вместо
    /// второго перебора всех отрезков.
    static func routeSpots(points: [MKMapPoint], cameras: [(camera: Camera, along: Double)]) -> [Int: Spot] {
        guard points.count >= 2 else { return [:] }
        var cum = [Double](repeating: 0, count: points.count)
        for index in 1..<points.count { cum[index] = cum[index - 1] + points[index - 1].distance(to: points[index]) }
        var out: [Int: Spot] = [:]
        out.reserveCapacity(cameras.count)
        for item in cameras {
            // Последний отрезок, чьё начало не дальше `along`.
            var low = 0, high = points.count - 2
            while low < high {
                let middle = (low + high + 1) / 2
                if cum[middle] <= item.along { low = middle } else { high = middle - 1 }
            }
            let length = cum[low + 1] - cum[low]
            let t = length > 0 ? max(0, min(1, (item.along - cum[low]) / length)) : 0
            out[item.camera.id] = spot(of: item.camera, on: points, segment: low, t: t)
        }
        return out
    }

    /// Точка одной камеры перебором отрезков — когда `along` неизвестен.
    static func spot(of camera: Camera, on points: [MKMapPoint]) -> Spot? {
        guard points.count >= 2 else { return nil }
        let target = MKMapPoint(camera.coordinate)
        // Сравниваем квадраты в единицах карты (масштаб вокруг камеры
        // постоянен): `distance` на каждый отрезок стоил бы корня и широты.
        var best2 = Double.greatestFiniteMagnitude
        var bestIndex = 0
        var bestT = 0.0
        for index in 0..<(points.count - 1) {
            let a = points[index], b = points[index + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? max(0, min(1, ((target.x - a.x) * dx + (target.y - a.y) * dy) / len2)) : 0
            let cx = a.x + t * dx - target.x, cy = a.y + t * dy - target.y
            let d2 = cx * cx + cy * cy
            if d2 < best2 { best2 = d2; bestIndex = index; bestT = t }
        }
        return spot(of: camera, on: points, segment: bestIndex, t: bestT)
    }

    /// Вердикт для точки проекции на отрезке `segment` в доле `t`.
    static func spot(of camera: Camera, on points: [MKMapPoint], segment: Int, t: Double) -> Spot {
        let a = points[segment], b = points[segment + 1]
        let projected = MKMapPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y))
        let offset = MKMapPoint(camera.coordinate).distance(to: projected)
        let headings = routeHeadings(points: points, segment: segment, t: t)
        // Не наша — только если не сходится НИ С ОДНИМ курсом линии у этой
        // точки: у вершины (поворот) камера может стоять на любой из улиц.
        let verdict: Verdict
        if !headings.isEmpty, headings.allSatisfy({ provesNotOurs(camera, heading: $0) }) {
            verdict = .notOurs
        } else if offset <= AppConfig.cameraOnLineMaxMeters {
            verdict = .onLine
        } else {
            verdict = .beside
        }
        return Spot(point: Point(projected.coordinate), verdict: verdict)
    }

    /// Курс линии у точки проекции: отрезок под ней, а у вершины (ближе
    /// `cameraOnLineVertexMeters`) — и соседний. Нулевые отрезки пропускаются.
    static func routeHeadings(points: [MKMapPoint], segment: Int, t: Double) -> [Double] {
        func heading(_ index: Int) -> Double? {
            guard index >= 0, index + 1 < points.count,
                  points[index].distance(to: points[index + 1]) > 0.5 else { return nil }
            return GeoMath.bearing(from: points[index].coordinate, to: points[index + 1].coordinate)
        }
        var out: [Double] = []
        if let own = heading(segment) { out.append(own) }
        let length = points[segment].distance(to: points[segment + 1])
        if t * length <= AppConfig.cameraOnLineVertexMeters, let before = heading(segment - 1) {
            out.append(before)
        }
        if (1 - t) * length <= AppConfig.cameraOnLineVertexMeters, let after = heading(segment + 1) {
            out.append(after)
        }
        return out
    }

    /// Доказательство «камера не для этого курса» — те же признаки и пороги,
    /// что у шага 2 гейтов (LocationGates.verdict), но против курса ЛИНИИ, а
    /// не нашего фикса. Направление — только при доказанно поделённых
    /// сторонах; ось — только у профиля, которому доверена тишина.
    /// Отметки водителей и свои точки профиля не имеют — никогда не «не наши».
    static func provesNotOurs(_ camera: Camera, heading: Double) -> Bool {
        if camera.allowsDirectionGate, let direction = camera.dir {
            return GeoMath.angleDifference(heading, Double(direction)) > AppConfig.cameraDirectionMaxAngle
        }
        guard camera.profileMayMute, let axis = cameraAxis(camera) else { return false }
        return GeoMath.axisDifference(course: heading, axis: axis) > AppConfig.cameraAxisMaxAngle
    }

    /// Ось дороги у самой камеры: с её куска дороги, иначе из базы.
    static func cameraAxis(_ camera: Camera) -> Double? {
        RoadShape(camera: camera)?.axis(near: camera.coordinate) ?? camera.axis.map(Double.init)
    }

    // MARK: - Без маршрута (ось нашей дороги)

    /// Точка ближайшей камеры на оси нашей дороги: прямая через прижатую
    /// точку `origin` по курсу дороги `bearing`. nil — камера не на этой оси
    /// (позади, далеко впереди, сбоку дальше допуска, её дорога идёт иначе
    /// или доказано не для нашего курса) — тогда она на своей координате.
    static func roadSpot(camera: Camera, origin: CLLocationCoordinate2D, bearing: Double) -> Point? {
        guard !provesNotOurs(camera, heading: bearing),
              // Ось неизвестна — не знаем, прямая ли дорога: не переносим.
              let axis = cameraAxis(camera),
              GeoMath.axisDifference(course: bearing, axis: axis) <= AppConfig.cameraOnRoadMaxAxisDegrees
        else { return nil }
        let metersPerLon = 111_320.0 * cos(origin.latitude * .pi / 180)
        let x = (camera.lon - origin.longitude) * metersPerLon
        let y = (camera.lat - origin.latitude) * 111_320.0
        let angle = bearing * .pi / 180
        let ux = sin(angle), uy = cos(angle)
        let along = x * ux + y * uy
        let lateral = abs(x * uy - y * ux)
        guard along > 0, along <= AppConfig.cameraOnRoadMaxAheadMeters,
              lateral <= AppConfig.cameraOnLineMaxMeters else { return nil }
        return Point(latitude: origin.latitude + along * uy / 111_320.0,
                     longitude: origin.longitude + along * ux / metersPerLon)
    }

    // MARK: - Кадр (дёшево)

    /// Что рисовать сейчас.
    /// - Parameters:
    ///   - route: камеры маршрута и метры от старта по линии.
    ///   - spots: точки маршрута (`routeSpots`); камера без точки — на своей
    ///     координате и на пути (неизвестно — показывать).
    ///   - progress: где мы на линии; nil — маршрута нет.
    ///   - nearest: ближайшая наша камера для показа (HUD).
    ///   - nearestOnRoad: её точка на оси нашей дороги (`roadSpot`), только
    ///     без маршрута.
    static func display(route: [(id: Int, along: Double)], spots: [Int: Spot], progress: Double?,
                        passedTolerance: Double, nearest: Int?, nearestOnRoad: Point?) -> Display {
        var display = Display()
        if let progress {
            // Встречный близнец не на пути ни впереди, ни как «ближайшая»:
            // линия маршрута доказывает, что он снимает не нас.
            let ours = route.filter { spots[$0.id]?.verdict != .notOurs }
            let nearestOurs = nearest.flatMap { spots[$0]?.verdict == .notOurs ? nil : $0 }
            display.pathIDs = CameraMarkerLook.pathIDs(route: ours, progress: progress,
                                                       passedTolerance: passedTolerance,
                                                       nearest: nearestOurs)
            // На линии — и проехавшие: мы проехали их по этой линии, а прыжок
            // значка вбок за машиной читался бы поломкой.
            for camera in route {
                if let spot = spots[camera.id], spot.verdict == .onLine {
                    display.points[camera.id] = spot.point
                }
            }
        } else {
            display.pathIDs = CameraMarkerLook.pathIDs(route: [], progress: nil,
                                                       passedTolerance: passedTolerance, nearest: nearest)
            if let nearest, let point = nearestOnRoad { display.points[nearest] = point }
        }
        return display
    }
}
