//
//  RoadSketch.swift
//  RadarMap
//
//  Схема дороги для приборки: где камера относительно МЕНЯ и МОЕЙ дороги.
//
//  Зачем своя схема, а не карта. Приборка — режим «телефон лежит в держателе»:
//  он должен беречь заряд и отвечать на один вопрос. Карта MapKit для этого
//  негодна дважды: она тянет тайлы (сеть, трафик, батарея — а за городом ещё и
//  серый экран), и её надо ЧИТАТЬ — найти себя, найти точку, соотнести с
//  дорогой. Это секунды внимания там, где есть доли.
//
//  А чертить есть из чего: у 3455 камер из 3467 в базе лежит кусок их
//  СОБСТВЕННОЙ проезжей части (`Camera.road`, медиана 200 м). Значит дорогу
//  камеры можно нарисовать по-настоящему, локально, без единого байта сети.
//
//  Схема ориентирована ПО ХОДУ ДВИЖЕНИЯ: мой курс — вверх. Тогда дорога камеры
//  на экране либо идёт вертикально (камера на моей дороге), либо пересекает
//  вид поперёк (камера на другой улице) — и это видно мгновенно, без чтения.
//  Ровно тот вопрос, на который приложение до сих пор не отвечало никак.
//
//  Чистая геометрия, покрыта RoadSketchTests.
//

import CoreLocation
import CoreGraphics
import Foundation

nonisolated enum RoadSketch {

    /// Раскладка в координатах вида: 0…1 по обеим осям, y растёт ВНИЗ (как в
    /// SwiftUI). Всё, что нужно для отрисовки, уже посчитано — вью только чертит.
    struct Layout: Equatable {
        /// Проезжая часть камеры, продлённая до краёв вида.
        var road: [CGPoint] = []
        /// Построенный маршрут — та самая жирная линия «куда я еду».
        var route: [CGPoint] = []
        /// Откуда я приехал: хвост трека поездки. Даёт схеме контекст улицы
        /// вместо линии в пустоте.
        var track: [CGPoint] = []
        /// Камера. `nil` — камер впереди нет, чертим только себя и маршрут.
        var camera: CGPoint?
        /// Я. Всегда в одной точке — схема движется относительно меня, а не наоборот.
        var me: CGPoint = .init(x: 0.5, y: meY)
        /// Сколько метров укладывается по высоте вида (для подписи масштаба).
        var spanMeters: Double = minSpanMeters
        /// Дорога камеры нарисована по её реальной геометрии, а не предположена
        /// по оси. Вью показывает предположение бледнее — обещать точность,
        /// которой нет, нельзя.
        var roadIsMeasured = false

        var isEmpty: Bool { road.isEmpty && route.isEmpty && track.isEmpty && camera == nil }
    }

    /// Где стоит «я»: не в центре, а ниже — впереди должно быть видно больше,
    /// чем позади. Тот же приём, что у любого навигатора.
    static let meY: Double = 0.78

    /// Минимальный охват: на близкой дистанции нельзя раздувать масштаб до
    /// сантиметров, иначе схема дёргается от шума GPS.
    static let minSpanMeters: Double = 140

    /// Максимальный охват. Схема отвечает на вопрос «где камера ОТНОСИТЕЛЬНО
    /// МЕНЯ И МОЕЙ ДОРОГИ», а он осмыслен только вблизи. На четырёх километрах
    /// всё сжимается в полосу, и главное — дорогу камеры пришлось бы дотянуть
    /// до меня продлением на километры, то есть выдумать. Камера дальше охвата
    /// на схеме просто не рисуется: расстояние скажет цифра.
    static let maxSpanMeters: Double = 700

    /// На сколько вправе продлевать кусок дороги за его измеренные концы.
    /// Кусок короткий (медиана 200 м), и на прямой продление честно — но
    /// только на своём порядке длины. Дальше начинается сочинение геометрии.
    static let maxExtensionMeters: Double = 180

    /// Построить раскладку. `nil` — чертить нечего (нет курса: на стоянке
    /// «по ходу движения» не определено, и схема соврала бы направлением).
    ///
    /// Сетку окрестных улиц не рисуем и не будем: дорожного графа на телефоне
    /// нет, а придумывать улицы, которых мы не знаем, — это ровно то враньё,
    /// от которого приложение и должно быть свободно. Чертим только измеренное:
    /// проезжую часть камеры из базы, построенный маршрут и собственный трек.
    static func layout(camera: Camera?,
                       route: [CLLocationCoordinate2D] = [],
                       track: [CLLocationCoordinate2D] = [],
                       from me: CLLocationCoordinate2D,
                       courseDegrees: Double,
                       aspect: Double) -> Layout? {
        guard courseDegrees >= 0, aspect > 0 else { return nil }

        let metersPerLon = 111_320.0 * cos(me.latitude * .pi / 180)
        /// Метры относительно меня, повёрнутые так, что мой курс — вверх (+y).
        func local(_ point: CLLocationCoordinate2D) -> CGPoint {
            let east = (point.longitude - me.longitude) * metersPerLon
            let north = (point.latitude - me.latitude) * 111_320.0
            // Знак положительный, и это не мелочь: точка по курсу обязана
            // оказаться строго ВВЕРХУ. С обратным знаком поворот давал
            // x = d·sin(2·курс) — на курсе 45° камера уезжала вбок, и дорога,
            // по которой едешь, рисовалась поперёк экрана.
            let angle = courseDegrees * .pi / 180
            return CGPoint(x: east * cos(angle) - north * sin(angle),
                           y: east * sin(angle) + north * cos(angle))
        }

        let rawCameraPoint = camera.map { local($0.coordinate) }
        let distance = rawCameraPoint.map { hypot($0.x, $0.y) } ?? 0
        // Охват подбираем от дистанции: камера должна попасть в верхнюю часть
        // вида с запасом, а не упираться в край, — но не дальше maxSpanMeters.
        let span = min(maxSpanMeters, max(minSpanMeters, distance / (meY - 0.12)))
        // Камера за охватом на схеме не появляется вовсе. Показать её у края
        // значило бы соврать масштабом, а дотянуть к ней дорогу — геометрией.
        let inRange = distance <= span * (meY - 0.05)
        let cameraPoint = inRange ? rawCameraPoint : nil

        /// Метры → координаты вида.
        func project(_ point: CGPoint) -> CGPoint {
            CGPoint(x: 0.5 + point.x / (span * aspect),
                    y: meY - point.y / span)
        }
        /// Отбросить всё, что заведомо за краями: маршрут бывает на сотни
        /// километров, а чертим мы двести метров вокруг себя.
        func nearby(_ points: [CLLocationCoordinate2D]) -> [CGPoint] {
            let limit = span * 2
            return points.map(local).filter { hypot($0.x, $0.y) <= limit }
        }

        var layout = Layout(camera: cameraPoint.map(project),
                            spanMeters: span)
        layout.route = nearby(route).map(project)
        layout.track = nearby(track).map(project)

        if let camera, let cameraPoint, inRange {
            let shape = RoadShape(camera: camera)
            layout.roadIsMeasured = (shape?.points.count ?? 0) >= 2
            let raw: [CGPoint] = if let shape, layout.roadIsMeasured {
                shape.points.map(local)
            } else if let axis = camera.axis {
                // Куска дороги нет (12 камер из 3467) — чертим ось как прямую
                // через камеру. Это предположение, и вью рисует его бледнее.
                straightLine(through: cameraPoint,
                             bearingDegrees: Double(axis) - courseDegrees,
                             halfLength: span)
            } else {
                []
            }
            layout.road = extended(raw, toReach: min(span * 0.5, maxExtensionMeters))
                .map(project)
        }
        return layout
    }

    /// Прямая через точку под заданным углом (0 = вверх, по часовой).
    private static func straightLine(through point: CGPoint, bearingDegrees: Double,
                                     halfLength: Double) -> [CGPoint] {
        let angle = bearingDegrees * .pi / 180
        let dx = sin(angle) * halfLength, dy = cos(angle) * halfLength
        return [CGPoint(x: point.x - dx, y: point.y - dy),
                CGPoint(x: point.x + dx, y: point.y + dy)]
    }

    /// Продлить ломаную с обоих концов по направлению крайних сегментов.
    ///
    /// Кусок дороги в базе короткий (медиана 200 м), а мы часто дальше него.
    /// Без продления линия висела бы в воздухе обрубком и читалась бы как
    /// «дорога кончается» — чего в жизни нет. Продлеваем ровно по направлению
    /// крайнего сегмента: на прямой это честно, а поворот в двухсотметровом
    /// куске всё равно не описан.
    static func extended(_ points: [CGPoint], toReach length: Double) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        var result = points
        func push(from a: CGPoint, to b: CGPoint) -> CGPoint {
            let dx = b.x - a.x, dy = b.y - a.y
            let norm = hypot(dx, dy)
            guard norm > 0.0001 else { return b }
            return CGPoint(x: b.x + dx / norm * length, y: b.y + dy / norm * length)
        }
        result.insert(push(from: points[1], to: points[0]), at: 0)
        result.append(push(from: points[points.count - 2], to: points[points.count - 1]))
        return result
    }
}
