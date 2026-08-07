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
//  Устройство — «север вверху» плюс точка зрения, и это разделение и есть
//  плавность за дёшево. СЦЕНА (Scene) строится в метрах вокруг опорной точки
//  без всякого курса и растеризуется вью ОДИН раз; между GPS-тиками движение
//  изображают три анимированных transform'а (сдвиг, поворот по курсу, зум),
//  которые компоновщик считает на GPU без единой перерисовки. Пересборка сцены
//  случается на смене данных или уходе от опоры (needsRebuild) — раз в сотни
//  метров, а не раз в секунду, как рисовала прежняя раскладка.
//
//  Всё, что в сцене, — измеренные данные: проезжая часть камеры из базы (есть
//  у 3455 камер из 3467), окрестная сеть из индекса лимитов, маршрут и свой
//  трек. Улицы, которых мы не знаем, не дорисовываются: пустота честнее
//  выдумки.
//
//  Чистая геометрия, покрыта RoadSketchTests и PerformanceBudgetTests.
//

import CoreLocation
import CoreGraphics
import Foundation

nonisolated enum RoadSketch {

    /// Дорога сети в сцене (метры относительно опоры, север — +y).
    struct Line: Equatable {
        var points: [CGPoint]
        var kind: RoadClass
        /// 0 — по земле, > 0 — мост, < 0 — тоннель. Рендерер рисует по
        /// возрастанию: мост ложится ПОВЕРХ того, что под ним.
        var level: Int
        var isOneWay: Bool
        var isDetailed: Bool
    }

    /// Камера в сцене: id нужен, чтобы вью подсветила тревожную кольцом.
    struct CameraDot: Equatable {
        var id: Int
        var point: CGPoint
    }

    /// Сцена «север вверху» в МЕТРАХ относительно опорной точки. Никакого
    /// курса и никакого экрана: и то и другое — дело точки зрения, которая
    /// меняется каждый тик, тогда как сцена живёт сотни метров.
    struct Scene: Equatable {
        /// Окрестная дорожная сеть — перекрёстки, развязки, параллельные улицы.
        var network: [Line] = []
        /// Проезжая часть тревожной камеры, продлённая по её направлению.
        var road: [CGPoint] = []
        /// Дорога камеры измерена снапом, а не предположена по оси. Вью
        /// показывает предположение бледнее — обещать точность, которой нет,
        /// нельзя.
        var roadIsMeasured = false
        /// Построенный маршрут — «куда я еду».
        var route: [CGPoint] = []
        /// Хвост трека поездки — «откуда я приехал».
        var track: [CGPoint] = []
        /// ВСЕ камеры охвата, а не только тревожная: на ферганском чорраха
        /// их четыре, и схема с одной точкой прятала три остальные.
        var cameras: [CameraDot] = []
        /// Камера, о которой сейчас предупреждаем (кольцо и её дорога). nil —
        /// тревожной в охвате нет.
        var alertCameraID: Int?
        var anchorLatitude: Double = 0
        var anchorLongitude: Double = 0
        /// Ступень масштаба, под которую растеризована сцена (метры по высоте
        /// вида). Вью докручивает точный масштаб scaleEffect'ом ≤ 1.
        var spanBucket: Double = minSpanMeters
        /// Охват в момент сборки: от него считаются дрейф до пересборки и
        /// сторона растра.
        var spanAtBuild: Double = minSpanMeters
        /// Радиус содержимого сцены вокруг опоры, метры.
        var radiusMeters: Double = 0

        var anchor: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: anchorLatitude, longitude: anchorLongitude)
        }
        var isEmpty: Bool {
            network.isEmpty && road.isEmpty && route.isEmpty && track.isEmpty
                && cameras.isEmpty
        }
        var alertCamera: CGPoint? {
            guard let alertCameraID else { return nil }
            return cameras.first { $0.id == alertCameraID }?.point
        }
    }

    /// Ключ пересборки: пока он совпадает и мы не уехали от опоры, растр
    /// переиспользуется как есть.
    struct RebuildKey: Equatable {
        var alertCameraID: Int?
        var alertInRange = false
        var spanBucket: Double = minSpanMeters
        var routeToken: ObjectIdentifier?
        var networkGeneration = 0
        /// Поколение дорожных тайлов: приехал тайл — растр пересобрать.
        var roadsGeneration = 0
        var storeRevision = 0
        var budget = 0
        /// Видны ли мелкие улицы (мы сами на такой): свернули во дворы —
        /// растр пересобрать с ними, выехали на проспект — без них.
        var minorRoads = false
    }

    // MARK: - Мелкие улицы

    /// Мелкая улица для схемы: прячется, пока мы не на такой же.
    ///
    /// На городском охвате (200–700 м) дворы и проезды превращают схему в
    /// паутину — see-скриншот из реальной поездки, где среди сетки переулков
    /// не читалась ДОРОГА. Настоящий навигатор мелочь на таком масштабе
    /// прячет. Правило одно: residential/service/pedestrian рисуются, только
    /// когда мы сами едем по такой улице — тогда они и есть наша местность.
    static func isMinorLine(_ line: RoadLine) -> Bool {
        line.isDetailed && isMinorClass(line.kind)
    }

    static func isMinorClass(_ kind: RoadClass) -> Bool {
        kind == .residential || kind == .service || kind == .pedestrian
    }

    /// Радиус, в котором ищем «свою» улицу.
    static let minorProbeRadiusMeters: Double = 60
    /// Ближе этого до мелкой улицы считаем, что едем по ней.
    static let minorOnRoadMeters: Double = 25

    /// Едем ли мы сейчас по мелкой улице: ближайшая К НАМ дорога — мелкая.
    ///
    /// Только детальные линии: источник, не знающий классов (индекс лимитов),
    /// мелочь не прячет вовсе — скрывать то, чего не знаешь, нельзя. На
    /// проспекте с дублёром в 15 м решает та дорога, что ближе: по ней мы и
    /// едем.
    static func prefersMinorRoads(network: RoadNetworkSource,
                                  at coordinate: CLLocationCoordinate2D) -> Bool {
        let lines = network.roads(near: coordinate, radius: minorProbeRadiusMeters)
        let metersPerLon = 111_320.0 * cos(coordinate.latitude * .pi / 180)
        var minor = Double.infinity
        var major = Double.infinity
        for line in lines where line.isDetailed {
            var previous: CGPoint?
            var nearest = Double.infinity
            for point in line.points {
                let local = CGPoint(
                    x: (point.longitude - coordinate.longitude) * metersPerLon,
                    y: (point.latitude - coordinate.latitude) * 111_320.0)
                if let a = previous {
                    // Расстояние до отрезка a–local от нуля (мы — начало координат).
                    let dx = local.x - a.x, dy = local.y - a.y
                    let len2 = dx * dx + dy * dy
                    let t = len2 > 0 ? max(0, min(1, (-a.x * dx - a.y * dy) / len2)) : 0
                    nearest = min(nearest, hypot(a.x + t * dx, a.y + t * dy))
                } else {
                    nearest = min(nearest, hypot(local.x, local.y))
                }
                previous = local
            }
            if isMinorClass(line.kind) { minor = min(minor, nearest) }
            else { major = min(major, nearest) }
        }
        return minor <= minorOnRoadMeters && minor <= major
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

    /// Шаг ступеней масштаба. Растр рисуется под ступень, точный масштаб
    /// добирает scaleEffect в пределах (1/ratio, 1] — сцена не пересобирается
    /// от каждого метра сближения с камерой.
    static let bucketRatio = 1.25

    /// Доля охвата, после которой уехали от опоры и растр надо пересобрать.
    static let rebuildDriftFactor = 0.35

    /// Сколько метров можно уехать от опоры, не пересобирая растр. Нижняя
    /// граница в метрах принципиальна: на минимальном охвате доля от 140 м —
    /// это пересборка каждые полсотни метров, то есть каждые пару секунд по
    /// городу. Запас оплачивается стороной растра, а не тиками.
    static func driftMeters(forSpan span: Double) -> Double {
        max(rebuildDriftFactor * span, 100)
    }

    /// Радиус сцены: круг видимости при любом повороте (до дальнего угла
    /// вида, ~1.5 охвата с запасом на докрутку масштаба) плюс дрейф до
    /// пересборки.
    static func sceneRadius(forSpan span: Double) -> Double {
        span * 1.55 + driftMeters(forSpan: span)
    }

    // MARK: - Точка зрения (каждый тик, чистая арифметика)

    /// Охват по дистанции до тревожной камеры: она должна попасть в верхнюю
    /// часть вида с запасом, а не упираться в край.
    static func span(forDistance distance: Double?) -> Double {
        guard let distance else { return minSpanMeters }
        return min(maxSpanMeters, max(minSpanMeters, distance / (meY - 0.12)))
    }

    /// Камера в охвате вида. За охватом она не рисуется вовсе: показать её у
    /// края значило бы соврать масштабом, а дотянуть к ней дорогу — геометрией.
    static func isInRange(distance: Double, span: Double) -> Bool {
        distance <= span * (meY - 0.05)
    }

    /// Ступень масштаба ≤ охвата: растр выходит чуть детальнее, чем нужно,
    /// и scaleEffect только СЖИМАЕТ (резкость не теряется).
    static func bucket(forSpan span: Double) -> Double {
        let steps = floor(log(span / minSpanMeters) / log(bucketRatio))
        return minSpanMeters * pow(bucketRatio, max(0, steps))
    }

    /// Длительность анимации точки зрения — по РЕАЛЬНОМУ ритму фиксов.
    ///
    /// Здесь была константа в 1 секунду, и она же была причиной рывков:
    /// адаптивный GPS на крейсере отдаёт фикс раз в 15–25 метров, в городе
    /// это 2–3 секунды — схема секунду ехала и две стояла. Навигаторы движутся
    /// плавно не потому, что фиксы частые, а потому, что анимируют ровно до
    /// следующего ожидаемого фикса: лучшее предсказание следующего интервала —
    /// предыдущий.
    ///
    /// Зажим сверху: после паузы (светофор, туннель) догонять точку зрения
    /// три секунды можно, дольше — уже враньё о том, где мы.
    static func animationDuration(sincePreviousTick dt: TimeInterval?) -> TimeInterval {
        min(max(dt ?? 1, 0.35), 3.0)
    }

    /// Размотанный курс: переход 359°→1° должен крутить схему на +2°, а не
    /// на −358° — анимация поворота интерполирует градусы как есть.
    ///
    /// nil — курса не было ни разу: повернуть схему наугад значило бы соврать
    /// направлением. Стоя (raw < 0) держим прошлое значение: мы никуда не
    /// повернули, и прошлый курс — честное описание того, как машина стоит.
    static func unwound(_ previous: Double?, towards raw: Double) -> Double? {
        guard raw >= 0 else { return previous }
        guard let previous else { return raw }
        var delta = (raw - previous).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return previous + delta
    }

    /// Точка сцены → координаты вида (0…1, y растёт вниз) при данной точке
    /// зрения. ОБЯЗАНА совпадать с transform'ами RoadSketchView — тесты
    /// поворота проверяют именно эту функцию.
    static func screenPoint(_ point: CGPoint, meOffset: CGPoint,
                            courseDegrees: Double, spanMeters: Double,
                            aspect: Double) -> CGPoint {
        let east = point.x - meOffset.x
        let north = point.y - meOffset.y
        // Знак положительный, и это не мелочь: точка по курсу обязана
        // оказаться строго ВВЕРХУ. С обратным знаком поворот давал
        // x = d·sin(2·курс) — на курсе 45° камера уезжала вбок, и дорога,
        // по которой едешь, рисовалась поперёк экрана.
        let angle = courseDegrees * .pi / 180
        let x = east * cos(angle) - north * sin(angle)
        let y = east * sin(angle) + north * cos(angle)
        return CGPoint(x: 0.5 + x / (spanMeters * aspect), y: meY - y / spanMeters)
    }

    /// Пора ли пересобирать растр: сменились данные или уехали от опоры.
    static func needsRebuild(scene: Scene?, key: RebuildKey, previousKey: RebuildKey?,
                             meOffsetMeters: CGPoint) -> Bool {
        guard let scene, key == previousKey else { return true }
        return hypot(meOffsetMeters.x, meOffsetMeters.y)
            > driftMeters(forSpan: scene.spanAtBuild)
    }

    /// Деление линейки масштаба: круглое число, занимающее заметную, но не
    /// доминирующую часть вида.
    static func scaleBarMeters(forSpan span: Double) -> Double {
        let candidates: [Double] = [50, 100, 200, 300, 500]
        return candidates.last { $0 <= span * 0.45 } ?? candidates[0]
    }

    // MARK: - Сцена (раз в сотни метров)

    /// Собрать сцену вокруг опоры. `meOffset` — где я относительно опоры в
    /// момент сборки: нужен бюджету сети, чтобы при урезании выживали БЛИЖНИЕ
    /// к машине линии.
    static func scene(alertCamera: Camera?, alertInRange: Bool,
                      cameras: [Camera] = [],
                      network: RoadNetworkSource = EmptyRoadNetwork(),
                      networkBudget: Int = .max,
                      showMinorRoads: Bool = true,
                      route: [CLLocationCoordinate2D] = [],
                      track: [CLLocationCoordinate2D] = [],
                      anchor: CLLocationCoordinate2D,
                      meOffset: CGPoint = .zero,
                      spanMeters: Double) -> Scene {
        let radius = sceneRadius(forSpan: spanMeters)
        let metersPerLon = 111_320.0 * cos(anchor.latitude * .pi / 180)
        /// Метры относительно опоры: восток +x, север +y. Никакого поворота —
        /// он дело точки зрения, а не сцены.
        func local(_ point: CLLocationCoordinate2D) -> CGPoint {
            CGPoint(x: (point.longitude - anchor.longitude) * metersPerLon,
                    y: (point.latitude - anchor.latitude) * 111_320.0)
        }
        /// Отбросить всё, что заведомо за растром, — ДО перевода в метры:
        /// маршрут бывает на сотни километров, а сцена — двухкилометровый круг.
        func nearby(_ points: [CLLocationCoordinate2D]) -> [CGPoint] {
            let maxLatDelta = radius / 111_320.0
            let maxLonDelta = radius / metersPerLon
            return points.compactMap { point in
                guard abs(point.latitude - anchor.latitude) <= maxLatDelta,
                      abs(point.longitude - anchor.longitude) <= maxLonDelta
                else { return nil }
                return local(point)
            }
        }

        var scene = Scene(anchorLatitude: anchor.latitude,
                          anchorLongitude: anchor.longitude,
                          spanBucket: bucket(forSpan: spanMeters),
                          spanAtBuild: spanMeters,
                          radiusMeters: radius)
        scene.route = nearby(route)
        scene.track = nearby(track)

        // Все камеры охвата — точками на своих местах. Тревожную гарантируем
        // отдельно: сторонний список мог её не включить (лимит, фильтр вида).
        // Камера на спрятанной мелкой улице прячется ВМЕСТЕ с улицей: точка
        // в чёрной пустоте без своей дороги читается как ошибка карты. Это
        // только картинка схемы — оповещение о такой камере не трогается,
        // а став тревожной, она рисуется гарантированно (ниже).
        scene.cameras = cameras.compactMap { camera in
            guard showMinorRoads || !isMinorClass(camera.roadClass) else { return nil }
            let point = local(camera.coordinate)
            guard hypot(point.x, point.y) <= radius else { return nil }
            return CameraDot(id: camera.id, point: point)
        }
        if alertInRange, let alertCamera {
            scene.alertCameraID = alertCamera.id
            if !scene.cameras.contains(where: { $0.id == alertCamera.id }) {
                scene.cameras.append(CameraDot(id: alertCamera.id,
                                               point: local(alertCamera.coordinate)))
            }
        }

        if networkBudget > 0 {
            let candidates = network
                .roads(near: anchor, radius: radius)
                .compactMap { line -> (line: Line, proximityMeters: Double)? in
                    guard line.points.count >= 2 else { return nil }
                    // Мелкие улицы — только когда мы сами на такой (фильтр ДО
                    // бюджета: бюджет обязан достаться видимым дорогам).
                    guard showMinorRoads || !isMinorLine(line) else { return nil }
                    // За один проход: перевод в метры, близость к машине и
                    // рамка линии.
                    var proximity = Double.greatestFiniteMagnitude
                    var minX = CGFloat.infinity, maxX = -CGFloat.infinity
                    var minY = CGFloat.infinity, maxY = -CGFloat.infinity
                    let points = line.points.map { coordinate -> CGPoint in
                        let point = local(coordinate)
                        proximity = min(proximity, max(abs(point.x - meOffset.x),
                                                       abs(point.y - meOffset.y)))
                        minX = min(minX, point.x); maxX = max(maxX, point.x)
                        minY = min(minY, point.y); maxY = max(maxY, point.y)
                        return point
                    }
                    // Линию целиком за квадратом растра незачем ни хранить,
                    // ни рисовать.
                    guard maxX >= -radius, minX <= radius,
                          maxY >= -radius, minY <= radius else { return nil }
                    return (Line(points: points, kind: line.kind, level: line.level,
                                 isOneWay: line.isOneWay, isDetailed: line.isDetailed),
                            proximity)
                }
            // Бюджет (даёт PerformanceMode): в перегрев остаются БЛИЖНИЕ линии.
            // Сеть — контекст, а не предупреждение: дорога камеры, маршрут и
            // трек не режутся ни на одной ступени, как и сами оповещения.
            let kept = candidates.count <= networkBudget
                ? candidates
                : Array(candidates.sorted { $0.proximityMeters < $1.proximityMeters }
                    .prefix(networkBudget))
            // Сначала земля, потом мосты: рендерер полагается на этот порядок.
            scene.network = kept.map(\.line).sorted { $0.level < $1.level }
        }

        // Дорога тревожной камеры. Пунктиром — если предположена по оси.
        if alertInRange, let alertCamera {
            let cameraPoint = local(alertCamera.coordinate)
            let shape = RoadShape(camera: alertCamera)
            scene.roadIsMeasured = (shape?.points.count ?? 0) >= 2
            let raw: [CGPoint] = if let shape, scene.roadIsMeasured {
                shape.points.map(local)
            } else if let axis = alertCamera.axis {
                // Куска дороги нет (12 камер из 3467) — чертим ось как прямую
                // через камеру. Это предположение, и вью рисует его бледнее.
                straightLine(through: cameraPoint, bearingDegrees: Double(axis),
                             halfLength: spanMeters)
            } else {
                []
            }
            scene.road = extended(raw, toReach: min(spanMeters * 0.5, maxExtensionMeters))
        }
        return scene
    }

    /// Прямая через точку под азимутом (0 = север, по часовой).
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
