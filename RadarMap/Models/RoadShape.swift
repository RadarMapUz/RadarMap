//
//  RoadShape.swift
//  RadarMap
//
//  Дорога камеры: класс и короткий кусок проезжей части вокруг неё.
//
//  Ось (0–179°) не различает направления, поэтому на разделённой дороге камера
//  обратной стороны считалась «нашей». Теперь у односторонних проезжих частей
//  есть направление (`dir`), а у камер — кусок геометрии их дороги: по нему
//  считается настоящее «я на этой дороге» (расстояние до ломаной), а не
//  эвристический коридор, и берётся истинный курс дороги в точке камеры — на
//  кривой одна ось врёт, а ломаная нет.
//
//  Чистые типы без CoreLocation-состояния, покрыты тестами (RoadShapeTests).
//

import CoreLocation

/// Класс дороги OSM — мгновенный контекст «город или трасса» и ширина полосы.
nonisolated enum RoadClass: Equatable {
    case motorway, trunk, primary, secondary, tertiary, residential, service
    /// Тротуар, переход, платформа: не проезжая часть.
    case pedestrian
    case unknown

    /// Постоянный код класса — для ключей. `hashValue` для этого не годится:
    /// он меняется от запуска к запуску, и обрезанный до байта совпадал у
    /// разных классов (1 из 256) — склейка дублей молча стирала мост над
    /// одноимённой улицей (флейки-тест 19.10).
    var stableCode: UInt8 {
        switch self {
        case .motorway: return 1
        case .trunk: return 2
        case .primary: return 3
        case .secondary: return 4
        case .tertiary: return 5
        case .residential: return 6
        case .service: return 7
        case .pedestrian: return 8
        case .unknown: return 0
        }
    }

    init(raw: String?) {
        switch raw {
        case "motorway", "motorway_link": self = .motorway
        case "trunk", "trunk_link":       self = .trunk
        case "primary", "primary_link":   self = .primary
        case "secondary", "secondary_link": self = .secondary
        case "tertiary", "tertiary_link": self = .tertiary
        case "residential", "living_street", "unclassified": self = .residential
        case "service", "track":          self = .service
        case "footway", "path", "cycleway", "steps", "pedestrian", "platform", "bus_stop":
            self = .pedestrian
        default:                          self = .unknown
        }
    }

    /// Обратно в значение OSM — его понимает сервер отметок (радиус слияния
    /// зависит от класса дороги). Обобщённые классы отдают своего
    /// представителя: точных подтипов сервер и не различает.
    var osmValue: String {
        switch self {
        case .motorway:   return "motorway"
        case .trunk:      return "trunk"
        case .primary:    return "primary"
        case .secondary:  return "secondary"
        case .tertiary:   return "tertiary"
        case .residential: return "residential"
        case .service:    return "service"
        case .pedestrian, .unknown: return ""
        }
    }

    /// Ширина одной полосы, метры.
    ///
    /// ВТОРАЯ ПОЛОВИНА КОНТРАКТА С СЕРВЕРОМ. Тайл возит не ширину, а число
    /// полос (старшие биты flags), и ширину считает клиент — по этой таблице.
    /// Она обязана совпадать с LANE_METERS в server/build_roads.py: разойдутся
    /// — и панель конструктора будет рисовать одну дорогу, а телефон другую.
    ///
    /// Проспект шире улицы не только числом полос, но и самой полосой. Двор
    /// считается одной полосой, но 3.5 м для него мало: разъезд в кармане —
    /// те же 4.5, что и в натуре.
    var laneMeters: Double {
        switch self {
        case .motorway, .trunk, .primary: return 3.75
        case .secondary, .tertiary, .residential: return 3.5
        case .service: return 4.5
        case .pedestrian, .unknown: return 3.5
        }
    }

    /// Сколько полос считать, когда тайл молчит (0 в старших битах). В OSM
    /// тег lanes стоит у 9 % дорог центра Ташкента — это основной путь, а не
    /// запасной. Числа ПОЛНЫЕ, как в самом теге: у двусторонней дороги это
    /// сумма обоих направлений. Совпадает с DEFAULT_LANES на сервере.
    func defaultLanes(isOneWay: Bool) -> Int {
        switch self {
        case .motorway, .trunk, .primary: return isOneWay ? 3 : 6
        case .secondary, .tertiary: return isOneWay ? 2 : 4
        case .residential: return isOneWay ? 1 : 2
        case .service: return 1
        case .pedestrian, .unknown: return isOneWay ? 1 : 2
        }
    }

    /// Потолок полос для класса. Совпадает с MAX_LANES_BY_CLASS на сервере.
    ///
    /// Сервер и так подрезает полосы перед записью в тайл, и всё же потолок
    /// стоит здесь тоже. Клиент не имеет права зависеть от чужой дисциплины:
    /// тайл приходит по сети, живёт в кэше неделями и переживает любую
    /// пересборку сервера. Без потолка одно поле в четыре бита превращается в
    /// дворовый проезд шириной 67 м — асфальт во весь квартал.
    var maxLanes: Int {
        switch self {
        case .motorway, .trunk: return 15
        case .primary: return 12
        case .secondary, .tertiary: return 8
        case .residential: return 4
        case .service: return 2
        case .pedestrian, .unknown: return 4
        }
    }

    /// Проезжая часть. Камера стоит над дорогой, а не над тротуаром, поэтому
    /// пешеходный класс — это признак ошибки сопоставления в снапе (в базе v10
    /// таких 39). Профилю такой «дороги» верить нельзя: её направление и
    /// геометрия к движению машин отношения не имеют, а переход и вовсе идёт
    /// ПОПЕРЁК проезжей части — по нему камера была бы заглушена гейтом оси.
    var isVehicleRoad: Bool { self != .pedestrian }

    /// Трасса по классу дороги: сигнал сильнее и мгновеннее, чем средняя скорость.
    var isHighway: Bool {
        self == .motorway || self == .trunk
    }

    /// Разбор кода из базы лимитов (формат 2). Контракт с сервером:
    /// ROAD_CLASS_CODES в server/extract_speed_limits.py присылает ровно эти
    /// числа, и тест на стороне сервера сторожит их диапазон. Чужое число —
    /// `.unknown`, а не падение: файл приезжает без подписи.
    init(code: Int) {
        switch code {
        case 1:  self = .motorway
        case 2:  self = .trunk
        case 3:  self = .primary
        case 4:  self = .secondary
        case 5:  self = .tertiary
        case 6:  self = .residential
        case 7:  self = .service
        case 8:  self = .pedestrian
        default: self = .unknown
        }
    }

    /// Магистральная дорога: та, где малый лимит — заявление, а не норма.
    /// На дворовом проезде 30 законны, на проспекте — повод усомниться.
    var isMajor: Bool {
        switch self {
        case .motorway, .trunk, .primary, .secondary: return true
        default: return false
        }
    }

    /// Городская улица — тихий режим оповещений даже при разгоне.
    var isCityStreet: Bool {
        self == .residential || self == .service
    }

    /// Предполагаемый лимит по классу дороги — когда `maxspeed` в OSM нет.
    ///
    /// Зачем вообще предполагать. Лимит известен примерно у трети камер, а без
    /// него не считается НИЧЕГО: ни превышение, ни рейтинг, ни «где теряете
    /// баллы», ни голос в режиме по умолчанию (он говорит о камере только при
    /// превышении, а превышения без лимита не бывает). То есть отсутствие
    /// одного числа гасит половину продукта, и предположение по классу дороги
    /// — гораздо лучшее приближение, чем «данных нет».
    ///
    /// Решает НЕ класс дороги, а «в населённом пункте или нет» — так устроены
    /// ПДД Узбекистана, и прежняя таблица этого не отражала.
    ///
    /// Пункт 10 ПДД: в населённом пункте легковому автомобилю 70 км/ч (с 2021
    /// года), вне населённого пункта 100, по автомагистрали 110. Класс дороги
    /// в этом правиле не участвует вовсе: и проспект, и жилая улица в городе —
    /// одни и те же 70.
    ///
    /// Прежние значения были занижены ровно там, где ездят: `residential` 30
    /// (а это OSM-класс обычной городской улицы, куда сваливаются ещё и
    /// `unclassified` с `living_street`), `primary`/`secondary` 70 на
    /// загородной дороге, где 100. Догадка кормит `isOverspeeding`, а он
    /// поднимает спокойный анонс камеры до сирены и включает фразу
    /// «Превышение скорости» — то есть приложение объявляло нарушением
    /// законные 60 в городе и законные 90 за городом. Комментарий выше при
    /// этом честно предупреждал, что так делать нельзя.
    ///
    /// Ошибка здесь несимметрична. Завышенная догадка молчит о нарушении —
    /// водитель ничего не теряет, потому что о камере ему всё равно скажут.
    /// Заниженная выдумывает нарушение, которого не было, и с этого начинается
    /// недоверие ко всем цифрам приложения.
    ///
    /// `nil` там, где предполагать нечего: тротуар и неизвестный класс — это
    /// промах снапа, а не дорога. `service` тоже `nil`, и это осознанно: во
    /// дворе штрафов не выписывают, а вот камера главной улицы, ошибочно
    /// севшая на служебный проезд (в базе таких 72), с догадкой в 20 км/ч
    /// объявляла бы нарушением любое движение.
    func assumedLimitKmh(inSettlement: Bool) -> Int? {
        switch self {
        case .motorway:
            return 110
        case .trunk, .primary, .secondary, .tertiary, .residential:
            return inSettlement ? 70 : 100
        case .service, .pedestrian, .unknown:
            return nil
        }
    }

    /// Догадка там, где живого контекста нет (карточка камеры, список).
    /// Автомагистраль и «трасса» по классу — заведомо загородные, всё
    /// остальное считаем населённым пунктом: в базе камер их подавляющее
    /// большинство.
    var assumedLimitKmhOffline: Int? {
        assumedLimitKmh(inSettlement: !isHighway)
    }

    /// Сколько полос ожидать, если тега `lanes` в OSM не было.
    /// Сколько полос у дороги этого класса не меньше — для ширины (`halfWidth`).
    var minimumLanes: Int {
        switch self {
        case .motorway, .trunk, .primary: return 2
        default: return 1
        }
    }

    var assumedLanes: Int {
        switch self {
        case .motorway, .trunk: return 4
        case .primary:          return 4
        case .secondary:        return 2
        case .tertiary:         return 2
        case .residential:      return 2
        case .service:          return 1
        // Пешеходный профиль — ошибка снапа; ширину берём как у обычной улицы,
        // потому что реальная дорога камеры где-то рядом.
        case .pedestrian:       return 2
        case .unknown:          return 2
        }
    }
}

/// Кусок проезжей части вокруг камеры, распакованный из базы.
nonisolated struct RoadShape {
    /// Точки дороги (обычно 3–9) вокруг камеры.
    let points: [CLLocationCoordinate2D]

    /// nil — у камеры нет куска дороги (старая база или снап не нашёл дорогу).
    init?(camera: Camera) {
        guard let road = camera.road, road.count >= 4, road.count % 2 == 0 else { return nil }
        var points: [CLLocationCoordinate2D] = []
        points.reserveCapacity(road.count / 2)
        for index in stride(from: 0, to: road.count, by: 2) {
            points.append(CLLocationCoordinate2D(
                latitude: camera.lat + Double(road[index]) / 1e6,
                longitude: camera.lon + Double(road[index + 1]) / 1e6))
        }
        self.points = points
    }

    /// Боковое отклонение точки от проезжей части камеры (метры) — честная
    /// проверка «я на этой дороге», различающая полосы разных направлений.
    ///
    /// `nil` — доказательства нет: кусок дороги кончился раньше нас, наша
    /// проекция лежит за его концом. Это НЕ «другая дорога», а «здесь нечего
    /// мерить»: кусок короткий (сотня метров, а на перекрёстке и того меньше,
    /// потому что в OSM дорога разрезана), и на подходе к камере мы почти всегда
    /// дальше его края. Раньше здесь мерилось обычное расстояние до ломаной, и
    /// продольный разрыв («до куска ещё 80 м») сравнивался с боковым допуском
    /// (~20 м) — камера глохла ровно на подъезде к ней, у всей базы.
    func lateralOffset(from coordinate: CLLocationCoordinate2D) -> Double? {
        guard let first = points.first, points.count >= 2 else { return nil }
        let metersPerLon = 111_320.0 * cos(first.latitude * .pi / 180)
        func flat(_ point: CLLocationCoordinate2D) -> (x: Double, y: Double) {
            ((point.longitude - first.longitude) * metersPerLon,
             (point.latitude - first.latitude) * 111_320.0)
        }
        let p = flat(coordinate)
        var best = Double.greatestFiniteMagnitude
        var bestIndex = 1
        var bestT = 0.0
        for index in 1..<points.count {
            let a = flat(points[index - 1]), b = flat(points[index])
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            guard len2 > 0 else { continue }   // дубликат вершины: отрезка нет
            let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
            let distance = hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
            if distance < best { best = distance; bestIndex = index; bestT = t }
        }
        guard best < .greatestFiniteMagnitude else { return nil }
        // Проекция упёрлась в самый КОНЕЦ ломаной — мы не сбоку от дороги, а за
        // её отрезком: воздерживаемся. Внутренние вершины не в счёт, там мы
        // по-прежнему вдоль дороги.
        let beyondStart = bestIndex == 1 && bestT <= 0
        let beyondEnd = bestIndex == points.count - 1 && bestT >= 1
        return (beyondStart || beyondEnd) ? nil : best
    }

    /// За краем куска — боковое смещение от ПРОДОЛЖЕНИЯ его крайнего отрезка
    /// (у того конца, к которому ближе точка): на плавной кривой честнее
    /// одной прямой через камеру — за 300 м по дуге радиусом 1 км прямая
    /// через камеру уходит от дороги на 45 м, продолжение конца — на 20.
    func extendedEndOffset(from coordinate: CLLocationCoordinate2D) -> Double? {
        guard points.count >= 2 else { return nil }
        let atStart = GeoMath.fastDistance(coordinate.latitude, coordinate.longitude,
                                           points[0].latitude, points[0].longitude)
            < GeoMath.fastDistance(coordinate.latitude, coordinate.longitude,
                                   points[points.count - 1].latitude, points[points.count - 1].longitude)
        let ordered = atStart ? Array(points) : Array(points.reversed())
        let end = ordered[0]
        let metersPerLon = 111_320.0 * cos(end.latitude * .pi / 180)
        func flat(_ point: CLLocationCoordinate2D) -> (x: Double, y: Double) {
            ((point.longitude - end.longitude) * metersPerLon, (point.latitude - end.latitude) * 111_320.0)
        }
        // Первая вершина, не совпадающая с концом, — направление крайнего отрезка.
        guard let inner = ordered.dropFirst().map(flat).first(where: { hypot($0.x, $0.y) > 0.5 }) else { return nil }
        let p = flat(coordinate)
        return abs(p.x * inner.y - p.y * inner.x) / hypot(inner.x, inner.y)
    }

    /// Ось (0–179°) ближайшего к точке участка дороги. На кривой это честнее
    /// единственной оси всей дороги, записанной в базе.
    func axis(near coordinate: CLLocationCoordinate2D) -> Double? {
        guard points.count >= 2 else { return nil }
        var best = Double.greatestFiniteMagnitude
        var bestIndex = 1
        for index in 1..<points.count {
            let middle = CLLocationCoordinate2D(
                latitude: (points[index - 1].latitude + points[index].latitude) / 2,
                longitude: (points[index - 1].longitude + points[index].longitude) / 2)
            let distance = GeoMath.fastDistance(coordinate.latitude, coordinate.longitude,
                                                middle.latitude, middle.longitude)
            if distance < best { best = distance; bestIndex = index }
        }
        let bearing = GeoMath.bearing(from: points[bestIndex - 1], to: points[bestIndex])
        return bearing.truncatingRemainder(dividingBy: 180)
    }
}

/// Геометрия ПРОЕЗДА: был ли он на самом деле.
///
/// Гейты оповещений и гейт записи в историю решают разные задачи, и у них
/// разная цена ошибки. Оповещение по подозрению стоит одного лишнего сигнала —
/// поэтому там всё щедро и неизвестность трактуется в пользу предупреждения.
/// Запись проезда по подозрению стоит ложного превышения, чужого перекрёстка
/// в «Где теряете баллы» и снятых баллов рейтинга — поэтому здесь неизвестность
/// НЕ трактуется никак: отклоняем только по доказательству.
///
/// Доказательств два, оба измеренные, а не эвристический конус коридора:
/// боковое отклонение от куска собственной проезжей части камеры (`road`,
/// есть у 99,7 % базы) — параллельная улица и дублёр; и курс поперёк оси её
/// дороги у самой камеры — поперечная улица перекрёстка, где кусок дороги
/// короче нас и боковое отклонение молчит. Оба — только для ЗАПИСИ проезда:
/// гейты оповещений они не трогают.
nonisolated enum PassGeometry {

    /// Насколько близко надо пройти, чтобы камера считалась пройденной.
    /// У камер со снапом координата стоит на оси дороги — порог узкий; у своих
    /// и краудсорсных точек её ставил человек, там остаётся прежний широкий.
    static func traverseLimit(for camera: Camera) -> CLLocationDistance {
        camera.hasTrustedRoadProfile && camera.road != nil
            ? AppConfig.passTraverseMaxMeters
            : AppConfig.passTraverseNoProfileMeters
    }

    /// Доказано ли, что в этой точке мы ехали НЕ по дороге камеры.
    ///
    /// `false` означает «доказательства нет», а не «мы на её дороге»: кусок
    /// дороги на перекрёстке бывает в два-три десятка метров (OSM режет улицу
    /// на огрызки), и тогда проекция уходит за его край, а `lateralOffset`
    /// честно возвращает nil. Такие случаи ловит порог траверза.
    static func isProvenOffRoad(camera: Camera,
                                at coordinate: CLLocationCoordinate2D) -> Bool {
        guard camera.hasTrustedRoadProfile,
              let shape = RoadShape(camera: camera),
              let lateral = shape.lateralOffset(from: coordinate) else { return false }
        return lateral > offRoadLimit(for: camera)
    }

    /// Отклонение курса от оси дороги камеры в этой точке, 0…90°, — сырьё
    /// второго доказательства «не наш проезд» (`isProvenCrossing`).
    ///
    /// nil — доказывать нечем:
    /// - курсу верить нельзя (`course < 0`: LocationFilter не дал курса) или
    ///   фикс хуже `courseProofMaxAccuracyMeters`: курс по земле на таком —
    ///   шум, а шум доказательством не бывает;
    /// - профилю нельзя доверить «не наша» (`profileMayMute`): у снапа на
    ///   тротуар, проезд или жилую зону ось чужая — радар трассы, севший на
    ///   поперечный проезд, иначе не писался бы никогда (3135, 3136 на D006);
    /// - позиция камеры не проверена (`needsReview`): снап не нашёл её дорогу
    ///   по имени, и ось может быть осью поперечной улицы;
    /// - оси нет вовсе (свои точки, краудсорс).
    ///
    /// Ось — с куска дороги у ТЕКУЩЕЙ точки, как у гейта оси: на кривой одна
    /// ось всей дороги врёт.
    static func axisDeviation(camera: Camera, at coordinate: CLLocationCoordinate2D,
                              course: CLLocationDirection,
                              accuracy: CLLocationAccuracy) -> Double? {
        guard course >= 0, accuracy <= AppConfig.courseProofMaxAccuracyMeters,
              camera.profileMayMute, camera.needsReview != true,
              let axis = RoadShape(camera: camera)?.axis(near: coordinate)
                ?? camera.axis.map(Double.init) else { return nil }
        return GeoMath.axisDifference(course: course, axis: axis)
    }

    /// Доказано ли курсом, что у камеры мы ПЕРЕСЕКАЛИ её дорогу, а не ехали
    /// по ней: медиана отклонений на тиках у самой камеры больше
    /// `passCrossingMinAngle`.
    ///
    /// Медиана, а не один тик сближения: курс по земле на соседних фиксах
    /// гуляет на ±5–10°, и именно тик минимума у 2676 был самым «прямым» из
    /// восьми. Медиане нужно большинство тиков поперёк: свернули с поперечной
    /// улицы на дорогу камеры до неё — у самой камеры большинство тиков вдоль,
    /// доказательства нет, и проезд судят прежние гейты. Пусто (курса не было
    /// или профиль не годится) — доказательства нет, как и раньше.
    static func isProvenCrossing(_ deviations: [Double]) -> Bool {
        guard !deviations.isEmpty else { return false }
        let sorted = deviations.sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
        return median > AppConfig.passCrossingMinAngle
    }

    /// Дальше этого сбоку от дороги камеры — уже не её дорога.
    static func offRoadLimit(for camera: Camera) -> Double {
        let width = RoadGeometry.halfWidth(lanes: camera.lanes, roadClass: camera.roadClass)
        return max(AppConfig.passOffRoadMeters, width * AppConfig.passOffRoadFactor)
    }

    /// Боковое смещение от СВОЕЙ дороги камеры: на её куске — до ломаной, за
    /// краем — до продолжения крайнего отрезка; куска нет — до прямой через
    /// камеру по её оси. Коридор мерит сбоку от НАШЕГО курса, а на петле
    /// развязки курс на одну-три точки смотрит прямо на камеру — так
    /// проеханная камера «подъезжалась» заново с петли (ревью S4, третий
    /// круг). nil — нет ни доверенного куска, ни оси.
    static func ownRoadOffset(camera: Camera, at coordinate: CLLocationCoordinate2D) -> Double? {
        guard camera.hasTrustedRoadProfile else { return nil }
        if let shape = RoadShape(camera: camera) {
            if let lateral = shape.lateralOffset(from: coordinate) { return lateral }
            if let extended = shape.extendedEndOffset(from: coordinate) { return extended }
        }
        guard let axis = camera.axis.map(Double.init) else { return nil }
        return lineOffset(coordinate, through: camera.coordinate, bearing: axis)
    }

    /// Боковое смещение от прямой через `origin` по направлению `bearing`
    /// (0° — север), метры.
    static func lineOffset(_ coordinate: CLLocationCoordinate2D, through origin: CLLocationCoordinate2D,
                           bearing: Double) -> Double {
        let metersPerLon = 111_320.0 * cos(origin.latitude * .pi / 180)
        let x = (coordinate.longitude - origin.longitude) * metersPerLon
        let y = (coordinate.latitude - origin.latitude) * 111_320.0
        let angle = bearing * .pi / 180
        // |P × d|, d = (sin, cos) — единичный вектор направления.
        return abs(x * cos(angle) - y * sin(angle))
    }

    /// Предел «своей дороги» для нового подъезда: ширина дороги камеры с
    /// запасом; камере с недоказанными сторонами — и дальняя проезжая часть.
    static func reapproachLimit(for camera: Camera) -> Double {
        camera.sidesAreProven ? offRoadLimit(for: camera)
                              : max(offRoadLimit(for: camera), AppConfig.reapproachUnprovenMeters)
    }
}

nonisolated enum RoadGeometry {
    /// Половина ширины проезжей части плюс запас на неточность координаты в
    /// реестре: до этого расстояния от ломаной считаем, что мы на этой дороге.
    /// Раньше это была одна константа на весь город (30 м), из-за которой
    /// параллельная проезжая часть в 20 м попадала в «нашу дорогу».
    static func halfWidth(lanes: Int?, roadClass: RoadClass) -> Double {
        // Не уже минимума класса: `lanes=1` на trunk/primary — чаще всего
        // ошибка тега (509, 2205, 3091…), а узкая «дорога» камеры выводила
        // машину в крайнем ряду за её ширину — и при доказанных сторонах
        // камера глушилась (11.2). Шире — безопасная сторона.
        let count = max(roadClass.minimumLanes, lanes ?? roadClass.assumedLanes)
        let roadWidth = Double(count) * AppConfig.laneWidthMeters
        return roadWidth / 2 + AppConfig.roadPositionSlackMeters
    }
}
