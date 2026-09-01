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
        /// Кольцевая развязка: контур замыкается, шевронов нет.
        var isRing = false
        /// Схлопнутая раздельная проезжая часть: две односторонние встречных
        /// направлений, сведённые в одну ось. Рисуется шире обычной — она и
        /// есть две дороги.
        var isDual = false
        /// Полос всего, как в теге OSM. 0 — тайл не сказал, ширина берётся
        /// дефолтом класса. От неё зависит толщина полотна в метрах.
        var lanes = 0
        /// Название улицы. Пусто — тайл его не знает: имя есть примерно у
        /// одной дороги из семи, и это нормальное состояние.
        var name = ""

        /// Полос, по которым считается ширина и раскладываются разделительные.
        var laneCount: Int {
            min(lanes > 0 ? lanes : kind.defaultLanes(isOneWay: isOneWay), kind.maxLanes)
        }

        /// Ширина проезжей части, метры.
        var widthMeters: Double { Double(laneCount) * kind.laneMeters }
    }

    /// Местность в сцене: вода, зелень, рельсы, кварталы — в метрах от опоры.
    /// Рисуется самым нижним слоем, ПОД дорогами: это то, по чему они идут.
    struct Area: Equatable {
        var points: [CGPoint]
        var kind: SketchArea.Kind
        var isClosed: Bool
        /// Этажей у дома; 0 — не сказано. Едет до вью, потому что объём
        /// рисуется именно там, а сцена живёт сотни метров и считается раз.
        var levels: Int = 0
        /// Класс дороги у полотна; 0 — не сказано. Едет тем же путём и по той
        /// же причине, что этажность: цвет асфальта выбирает вью.
        ///
        /// Поля здесь не было, а вью его спрашивало — модуль не собирался.
        /// Проспект и двор обязаны отличаться заливкой, иначе город станет
        /// одного тона; без класса пришлось бы взять средний и потерять
        /// разницу ровно там, где она видна лучше всего.
        var roadClass: Int = 0
    }

    /// Точечный объект в сцене: метры от опоры. Нарисован руками в панели,
    /// поэтому виден только вблизи — на охвате района это пиксель среди
    /// сотни таких же.
    struct Mark: Equatable {
        var point: CGPoint
        var kind: SketchPoint.Kind
    }

    /// Подпись улицы.
    ///
    /// Единственное со снимка чужого навигатора, что у нас было в данных и не
    /// рисовалось: имя приезжает в тайле четвёртым элементом записи и до
    /// экрана не доходило.
    ///
    /// Угол — вдоль улицы, а не горизонтально: подпись поперёк дороги читается
    /// как чужая, и на перекрёстке непонятно, к какой из двух она относится.
    /// Но никогда вверх ногами: угол приводится к «читаемой» половине круга.
    struct Label: Equatable {
        var text: String
        /// Середина видимого куска улицы, в метрах от опоры сцены.
        var point: CGPoint
        /// Направление улицы на экране, градусы.
        var angle: Double
    }

    /// Краска на асфальте: зебра, стоп-линия. Отрезок ПОПЕРЁК проезжей части,
    /// заданный серединой, направлением дороги и её шириной — в метрах от
    /// опоры, как и всё остальное в сцене.
    ///
    /// Отдельно от Mark, потому что рисуется в другом слое: краска живёт в
    /// растре и поворачивается вместе с дорогой, значок — в слое, которому
    /// курс возвращён, чтобы он стоял прямо.
    struct Marking: Equatable {
        var point: CGPoint
        var kind: SketchPoint.Kind
        /// Направление дороги, градусы (0 — на север). Черта идёт поперёк.
        var azimuthDegrees: Double
        var widthMeters: Double
        /// Куда можно с каждой полосы, слева направо. Пусто у зебры и стоп-линии.
        var turns: [LaneTurn] = []

        /// Концы черты в метрах от опоры. Азимут — компасный, поэтому вдоль
        /// дороги это (sin, cos), а поперёк — (cos, −sin).
        var ends: (CGPoint, CGPoint) {
            let radians = azimuthDegrees * .pi / 180
            let half = CGFloat(widthMeters) / 2
            let across = CGPoint(x: CoreGraphics.cos(radians) * half,
                                 y: -CoreGraphics.sin(radians) * half)
            return (CGPoint(x: point.x - across.x, y: point.y - across.y),
                    CGPoint(x: point.x + across.x, y: point.y + across.y))
        }
    }

    /// Камера в сцене: id нужен, чтобы вью подсветила тревожную кольцом.
    struct CameraDot: Equatable {
        var id: Int
        var point: CGPoint
        /// Куда смотрит камера, градусы. nil — НЕ ЗНАЕМ, и рисовать
        /// направление нельзя.
        ///
        /// `dir` в базе есть только у односторонних дорог, где OSM знает его
        /// однозначно. У двусторонней улицы куда смотрит камера, не знает
        /// никто — и выдуманный конус водитель однажды поймает, а после этого
        /// перестанет верить и правде.
        var facing: Double?
        /// Ось дороги камеры, градусы (0–179, ненаправленная). Есть почти
        /// всегда и говорит меньше: «камера следит вот за этой линией», без
        /// стороны.
        var axis: Double?
    }

    /// Сцена «север вверху» в МЕТРАХ относительно опорной точки. Никакого
    /// курса и никакого экрана: и то и другое — дело точки зрения, которая
    /// меняется каждый тик, тогда как сцена живёт сотни метров.
    struct Scene: Equatable {
        /// Местность под дорогами. Пусто — слои не приехали, и это нормальное
        /// состояние: схема рисует то, что знает.
        var areas: [Area] = []
        /// Краска на асфальте: зебры и стоп-линии. Рисуется в растре.
        var markings: [Marking] = []
        /// Светофоры, развороты и прочее, нарисованное руками.
        var marks: [Mark] = []
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
        /// Полотно легло ЦЕЛИКОМ: все проезжие части кадра и все площади
        /// перекрёстков поместились в бюджет.
        ///
        /// Признаком, а не подсчётом во вью. Вью раньше спрашивало «есть ли
        /// хоть одна фигура полотна» и по этому ответу переставало чертить
        /// сеть штрихами — а в перегреве бюджет резал полотно посередине:
        /// оставались куски асфальта без перекрёстков и без штрихов между
        /// ними. Ровно это и выглядело как рваные дороги.
        var hasPavement = false

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
        /// Поколение местности: приехал слой воды — растр пересобрать.
        var areasGeneration = 0
        /// Поколение ручных объектов: приехал светофор — растр пересобрать.
        var marksGeneration = 0
        /// Схема перешла на костяк района. В ключе явно, а не «через
        /// spanBucket»: порог костяка (340 м) лежит МЕЖДУ ступенями масштаба
        /// 273 и 342, и в этом окне источник сети менялся, а ключ — нет.
        /// Растр оставался собранным по прежней сети, то есть на экране была
        /// картинка не из того источника, из которого её считали.
        var farNetwork = false
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

    /// Ближе этого считаем, что едем ИМЕННО по этой улице. Тот же порядок,
    /// что у гейта мелких улиц: на проспекте с дублёром решает та дорога, что
    /// ближе.
    static let streetNameRadiusMeters: Double = 30

    /// Имя улицы под нами. nil — ближайшая дорога безымянна или далеко.
    ///
    /// «Безымянна» и «мы не знаем имени» здесь одно и то же, и подписывать
    /// нечего: пустая подпись под курсором хуже её отсутствия — она выглядит
    /// сломанной, а не честной.
    static func currentStreet(network: RoadNetworkSource,
                              at coordinate: CLLocationCoordinate2D) -> String? {
        let lines = network.roads(near: coordinate, radius: streetNameRadiusMeters)
        let metersPerLon = 111_320.0 * cos(coordinate.latitude * .pi / 180)
        var best: String?
        var bestDistance = streetNameRadiusMeters
        for line in lines where !line.name.isEmpty {
            var previous: CGPoint?
            for point in line.points {
                let local = CGPoint(
                    x: (point.longitude - coordinate.longitude) * metersPerLon,
                    y: (point.latitude - coordinate.latitude) * 111_320.0)
                let distance: Double
                if let a = previous {
                    let dx = local.x - a.x, dy = local.y - a.y
                    let length = dx * dx + dy * dy
                    let t = length > 0
                        ? max(0, min(1, (-a.x * dx - a.y * dy) / length)) : 0
                    distance = Double(hypot(a.x + t * dx, a.y + t * dy))
                } else {
                    distance = Double(hypot(local.x, local.y))
                }
                if distance < bestDistance {
                    bestDistance = distance
                    best = line.name
                }
                previous = local
            }
        }
        return best
    }

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
    ///
    /// Доля ВИДИМОЙ части вида, а не всего экрана: панели поверх схемы
    /// забирают себе четверть высоты, и считать от неё — значит ставить «я» и
    /// камеру не туда, где на них смотрят (см. Insets).
    static let meY: Double = 0.78

    /// Где стоит тревожная камера, когда охват выбирается по ней. Доля
    /// видимой части сверху.
    ///
    /// Пятнадцать процентов, а не двенадцать процентов ЭКРАНА, как было. Разница не
    /// в трёх процентах, а в том, от чего они считаются: карточка скорости
    /// занимает 17 % высоты (26 % с объявлением о перегреве), и камера,
    /// поставленная на 12 % экрана, рисовалась ПОД карточкой на каждом
    /// подходе. Проверено на снимке живой поездки: «344 м до камеры» в
    /// карточке — и ни одной камеры на карте.
    static let cameraTopShare: Double = 0.15

    /// Насколько близко к верхней кромке видимого камера ещё считается
    /// попавшей в охват. Ниже этого она была бы наполовину за краем.
    static let cameraEdgeShare: Double = 0.05

    /// Поля вида: какую долю высоты забирают панели поверх схемы.
    ///
    /// Схема лежит во весь экран, а видно из неё не всё: сверху карточка
    /// скорости и объявления, снизу панель поездки. Вся проекция считается от
    /// ВИДИМОГО прямоугольника — «я», камера, попадание в охват, поля растра.
    /// Хост измеряет свои панели сам и кладёт их сюда; приборка и CarPlay
    /// оставляют поля пустыми, потому что там схема ничем не закрыта.
    struct Insets: Equatable, Sendable {
        var top: Double = 0
        var bottom: Double = 0

        static let none = Insets()

        /// Потолок полей. Панель, забравшая больше двух третей экрана, — это
        /// уже не схема с панелью, и геометрия не обязана считать такой
        /// случай осмысленным; она обязана не сойти с ума.
        var safeTop: Double { min(max(0, top), 0.45) }
        var safeBottom: Double { min(max(0, bottom), 0.35) }

        /// Доля высоты, которая видна.
        var visible: Double { max(0.35, 1 - safeTop - safeBottom) }

        /// Где стоит «я» — доля ПОЛНОЙ высоты вида.
        var meY: Double { safeTop + visible * RoadSketch.meY }
        /// Куда охват ставит тревожную камеру — доля полной высоты.
        var cameraY: Double { safeTop + visible * RoadSketch.cameraTopShare }
        /// Верхняя кромка, за которую камера уже не считается видимой.
        var cameraEdgeY: Double { safeTop + visible * RoadSketch.cameraEdgeShare }
    }

    /// Минимальный охват: на близкой дистанции нельзя раздувать масштаб до
    /// сантиметров, иначе схема дёргается от шума GPS.
    static let minSpanMeters: Double = 140

    // MARK: - Вид вблизи
    //
    // Отдельная нижняя ступень масштаба для момента, когда важно не «что
    // впереди», а «где я и в какой полосе»: подход к манёвру, тревожная
    // камера рядом, двор или пробка.
    //
    // Включается СОБЫТИЕМ, а не скоростью. Медленно едут и в пробке на прямой,
    // где никакой подробности не нужно, — а на манёвре важна каждая полоса
    // независимо от того, ползём мы или катимся.

    /// Охват вида вблизи. Пятьдесят пять метров — это перекрёсток целиком с
    /// подходами: меньше — и не видно, куда сворачивать, больше — и полосы
    /// сливаются.
    static let closeSpanMeters: Double = 55

    /// Ближе этого до манёвра вид переходит вблизи. Полтораста метров — около
    /// девяти секунд на шестидесяти: столько нужно, чтобы успеть перестроиться.
    static let closeManeuverMeters: Double = 150
    /// Ближе этого до тревожной камеры — то же самое. Меньше, чем у манёвра:
    /// у камеры не надо перестраиваться, надо сбросить скорость.
    static let closeCameraMeters: Double = 120
    /// Медленнее этого и дольше `closeSlowSeconds` — двор или пробка.
    static let closeSlowKmh: Double = 20
    static let closeSlowSeconds: Double = 5

    /// Запас на выходе из ползания. Был 1,6 — то есть вид вблизи отпускал
    /// только выше 32 км/ч, а 32 км/ч это скорость городского потока, а не
    /// признак пробки. Постояли пять секунд на светофоре — и схема ехала на
    /// пятидесяти пяти метрах весь маршрут. Проверено на снимке: 29 км/ч,
    /// весь экран — стена асфальта.
    static let closeSlowExitFactor: Double = 1.25

    /// Выход обратно — с ЗАПАСОМ. Вид, дёргающийся между двумя масштабами на
    /// каждом перекрёстке, хуже любого из них, поэтому порог выхода дальше
    /// порога входа, и пока он не пройден, вид держится.
    static let closeExitMeters: Double = 250

    /// Что просит вида вблизи. Пусто — обычный охват.
    enum CloseReason: Equatable {
        case maneuver
        case camera
        case crawl
    }

    // MARK: - Своя полоса

    /// Хуже этой точности «своя полоса» — выдумка: полоса три с половиной
    /// метра, и на пяти метрах ошибки машину покажет в соседней.
    static let laneAccuracyMeters: Double = 3

    /// Боковое смещение машины от оси дороги, метры со знаком (плюс — правее
    /// по ходу). nil — показывать нельзя, машина остаётся на оси.
    ///
    /// Три отказа, и каждый — про честность, а не про удобство:
    ///
    /// — точность GPS хуже полосы: «своя полоса» перестаёт быть фактом;
    /// — полосы дороги не измерены: мы не знаем, сколько их и где они;
    /// — смещение больше половины проезжей части: значит мы не на этой дороге,
    ///   а рядом — на дублёре, на тротуаре или это промах посадки.
    ///
    /// Сглаживание — снаружи: здесь чистая геометрия, а дрожание гасит тот,
    /// кто знает предыдущее значение.
    static func laneOffset(me: CLLocationCoordinate2D,
                           onAxis: CLLocationCoordinate2D,
                           courseDegrees: Double,
                           roadWidthMeters: Double,
                           lanesMeasured: Bool,
                           accuracyMeters: Double) -> Double? {
        guard lanesMeasured else { return nil }
        guard accuracyMeters > 0, accuracyMeters <= laneAccuracyMeters else { return nil }
        guard roadWidthMeters > 0 else { return nil }

        let metresPerLon = 111_320.0 * cos(onAxis.latitude * .pi / 180)
        let east = (me.longitude - onAxis.longitude) * metresPerLon
        let north = (me.latitude - onAxis.latitude) * 111_320.0
        // Смещение ВПРАВО по ходу: поворачиваем вектор «ось → машина» в
        // систему курса. Вправо от курса — это (восток·cos − север·sin) при
        // курсе, отсчитанном от севера по часовой.
        let heading = courseDegrees * .pi / 180
        let right = east * cos(heading) - north * sin(heading)
        guard abs(right) <= roadWidthMeters / 2 else { return nil }
        return right
    }

    /// Нужен ли вид вблизи прямо сейчас.
    ///
    /// Чистая функция: всё состояние приходит аргументами, включая ПРЕЖНЕЕ
    /// решение — на нём и держится гистерезис. Без него один и тот же
    /// перекрёсток на границе порога включал бы и выключал вид каждую секунду.
    static func closeReason(toManeuver maneuver: Double?,
                            toCamera camera: Double?,
                            speedKmh: Double,
                            crawlingSeconds: Double,
                            onMinorRoad: Bool = false,
                            wasClose: Bool) -> CloseReason? {
        let enter = wasClose ? closeExitMeters : closeManeuverMeters
        if let maneuver, maneuver <= enter { return .maneuver }
        let cameraEnter = wasClose ? closeExitMeters : closeCameraMeters
        if let camera, camera <= cameraEnter { return .camera }
        // Ползание САМО ПО СЕБЕ вида вблизи не даёт, и это главная правка.
        // В пробке на прямом проспекте вблизи смотреть не на что, а масштаб,
        // залипший на светофоре, потом едет с водителем весь маршрут. Нужен
        // повод рядом: манёвр и камера проверены выше, остаётся двор — там
        // ползут не от пробки, а потому что приехали.
        let slowEnough = wasClose ? closeSlowKmh * closeSlowExitFactor : closeSlowKmh
        if onMinorRoad, speedKmh <= slowEnough, crawlingSeconds >= closeSlowSeconds {
            return .crawl
        }
        return nil
    }

    /// Охват вида вблизи. Не константа: он обязан ВМЕЩАТЬ свою причину.
    ///
    /// Вид включался из-за камеры в 120 метрах и показывал 43 метра вперёд —
    /// то есть первым делом стирал с экрана то, из-за чего включился, и
    /// возвращал камеру только с сорока метров. Восемьдесят метров подхода
    /// водитель смотрел на пустой асфальт и цифру в карточке.
    ///
    /// Правило простое: ступень вблизи — это НИЖНЯЯ граница охвата, а не сам
    /// охват. Пока причина далеко, охват её догоняет; чем ближе она, тем
    /// крупнее план, и на последних метрах он приходит к тем самым 55.
    static func closeSpan(reason: CloseReason, toManeuver: Double?,
                          toCamera: Double?, insets: Insets = .none) -> Double {
        let cause: Double? = switch reason {
        case .maneuver: toManeuver
        case .camera: toCamera
        case .crawl: nil
        }
        guard let cause, cause > 0 else { return closeSpanMeters }
        return min(maxSpanMeters, max(closeSpanMeters, cause / reach(insets)))
    }

    /// Охват, с которого схема переходит на костяк района: там раздельные
    /// проезжие уже сведены в одну ось, а мелких улиц нет вовсе. Совпадает с
    /// той ступенью, на которой из отбора по масштабу уходят жилые улицы.
    /// Охват, дальше которого с телефона уходит НАБОР улиц и остаётся один
    /// костяк района.
    ///
    /// Не про читаемость — рисовать улицы дальше 340 метров схема и так
    /// перестала (farNetworkSpan). Про цену: набор улиц весит 6,4 КБ на тайл,
    /// окрестность на охвате двадцати километров это восемьдесят один тайл, и
    /// полмегабайта уходило бы на линии, которых не будет на экране. Запас
    /// над farNetworkSpan оставлен нарочно: возврат к ближнему плану должен
    /// быть мгновенным, а не «подождите, качаю улицы обратно».
    static let streetsMaxSpan: Double = 1_500

    /// Бюджет сети под ОХВАТ, а не только под жару.
    ///
    /// Восемьдесят линий — мера вида в двести метров, где после склейки улица
    /// это одна линия. На охвате района тем же числом рисуется пятачок вокруг
    /// машины и пустота вокруг: сцена, выйдя за бюджет, оставляет БЛИЖНИЕ
    /// линии и выбрасывает дальние — то есть ровно то, на что жалуются
    /// словами «карта не рисует остальное место».
    ///
    /// Рост линейный по охвату, а не квадратичный по площади: с каждой
    /// ступенью масштаба из отбора уходит целый класс дорог (minimumRank), и
    /// число линий растёт много медленнее площади.
    static func networkBudget(base: Int, span: Double) -> Int {
        guard base > 0 else { return 0 }
        let growth = min(12, max(1, span / minSpanMeters))
        return Int((Double(base) * growth).rounded())
    }

    /// То же для местности. Потолок ниже: дальше трёх километров кварталы
    /// уходят, и в бюджете остаются вода, зелень и рельсы — их немного.
    static func areaBudget(base: Int, span: Double) -> Int {
        guard base > 0 else { return 0 }
        return Int((Double(base) * min(4, max(1, span / minSpanMeters))).rounded())
    }

    /// Потолок точечных объектов в кадре. Не оптимизация, а предохранитель:
    /// сервер сводит подъезды одного перекрёстка в один значок и мерил
    /// плотность (7 на ближнем плане, 10 на дальнем), но тайл приходит извне,
    /// и слой, который рисуется на тик, не должен зависеть от чужой щедрости.
    static let markBudget = 48

    /// Сколько подписей улиц рисовать разом.
    ///
    /// Двенадцать — не круглое число, а следствие двух ограничений. Каждая
    /// подпись перерисовывается на тик вместе со значками (ей возвращают
    /// курс), поэтому их число — прямая цена в кадре. И читаемость: больше
    /// дюжины строк на схеме размером в ладонь превращают карту в текст, по
    /// которому уже не видно дорог.
    static let labelBudget = 12

    /// Ближе этого по ЭКРАНУ две подписи читаются как одна — доля высоты
    /// вида, а не метры. Правило про чтение, а не про землю: девяносто метров,
    /// как было, на охвате вблизи означали одну подпись на весь экран, а на
    /// охвате района — толпу подписей в углу.
    static let labelApartShare: Double = 0.1

    /// Сколько экранных пунктов занимает буква подписи. Точную ширину строки
    /// в модели считать нечем и незачем: нужен ответ «влезает ли имя в видимый
    /// кусок улицы», и он не меняется от третьего знака.
    static let labelPointsPerCharacter: Double = 6.5

    /// Поля видимого прямоугольника, в которые подпись не заезжает.
    static let labelMarginShare: Double = 0.04

    /// Подпись ещё сидит на экране.
    ///
    /// Нужна, чтобы не пересаживать подписи каждый тик: пересчитанная на
    /// каждом фиксе подпись ползала бы по улице туда-сюда. Пока она видна —
    /// стоит где стояла; ушла за край — сажаем заново. Поле вдвое меньше
    /// того, с которым сажали: иначе подпись у самой кромки пересчитывалась
    /// бы каждый тик.
    static func isSeated(_ point: CGPoint, meOffset: CGPoint,
                         courseDegrees: Double, spanMeters: Double,
                         aspect: Double, insets: Insets = .none) -> Bool {
        guard spanMeters > 0, aspect > 0 else { return false }
        let seat = screenPoint(point, meOffset: meOffset, courseDegrees: courseDegrees,
                               spanMeters: spanMeters, aspect: aspect, insets: insets)
        let margin = labelMarginShare / 2
        return Double(seat.y) >= insets.safeTop + margin
            && Double(seat.y) <= 1 - insets.safeBottom - margin
            && Double(seat.x) >= margin / aspect
            && Double(seat.x) <= 1 - margin / aspect
    }

    /// Подписи для видимой сети.
    ///
    /// Считаются от ТОЧКИ ЗРЕНИЯ, а не от одной сцены, и в этом вся правка.
    /// Раньше подпись садилась в середину улицы, посчитанной по всему растру
    /// (радиус 185–990 метров), а человек смотрит в его сотую часть: середина
    /// уезжала за экран вместе с подписью. На четырёх снимках живой поездки
    /// не было НИ ОДНОЙ подписи при пяти-восьми подписываемых улицах в кадре.
    ///
    /// Теперь улица режется прямоугольником вида, и подпись садится в
    /// середину самого длинного ВИДИМОГО куска. Заодно отпадает порог длины в
    /// метрах: спрашиваем не «длинна ли улица», а «влезает ли в неё имя».
    ///
    /// Порядок отбора — по классу, а не по близости: на перекрёстке проспекта
    /// с проездом подписать надо проспект. При равном классе выигрывает более
    /// длинный видимый кусок.
    static func labels(for network: [Line], meOffset: CGPoint = .zero,
                       courseDegrees: Double = 0,
                       spanMeters: Double = minSpanMeters,
                       aspect: Double = 0.5, insets: Insets = .none,
                       viewHeight: Double = 800,
                       limit: Int = labelBudget) -> [Label] {
        guard spanMeters > 0, viewHeight > 0, aspect > 0 else { return [] }
        let marginY = labelMarginShare
        let minY = insets.safeTop + marginY
        let maxY = 1 - insets.safeBottom - marginY
        // По горизонтали поле в тех же долях ЭКРАНА, а не ширины: x у
        // screenPoint — доля ширины, и без деления на aspect поле сбоку вышло
        // бы вдвое уже поля сверху.
        let marginX = marginY / aspect
        let minX = marginX, maxX = 1 - marginX

        func screen(_ point: CGPoint) -> CGPoint {
            screenPoint(point, meOffset: meOffset, courseDegrees: courseDegrees,
                        spanMeters: spanMeters, aspect: aspect, insets: insets)
        }
        /// Видимая доля отрезка (Лианг — Барски). nil — отрезок целиком за
        /// краем. Доли, а не точки: преобразование вида аффинное, поэтому
        /// параметр отрезка одинаков на экране и в метрах сцены.
        func clip(_ a: CGPoint, _ b: CGPoint) -> (Double, Double)? {
            var near = 0.0, far = 1.0
            let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
            let edges: [(Double, Double)] = [
                (-dx, Double(a.x) - minX), (dx, maxX - Double(a.x)),
                (-dy, Double(a.y) - minY), (dy, maxY - Double(a.y)),
            ]
            for (slope, room) in edges {
                if slope == 0 {
                    if room < 0 { return nil }
                    continue
                }
                let cut = room / slope
                if slope < 0 {
                    if cut > far { return nil }
                    if cut > near { near = cut }
                } else {
                    if cut < near { return nil }
                    if cut < far { far = cut }
                }
            }
            return near < far ? (near, far) : nil
        }
        func between(_ a: CGPoint, _ b: CGPoint, _ share: Double) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * CGFloat(share),
                    y: a.y + (b.y - a.y) * CGFloat(share))
        }

        /// Самый длинный непрерывный кусок улицы внутри вида.
        func visibleRun(_ line: Line) -> [CGPoint] {
            var best: [CGPoint] = [], bestLength = 0.0
            var current: [CGPoint] = [], length = 0.0
            var touchedEnd = false
            func flush() {
                if length > bestLength { bestLength = length; best = current }
                current = []; length = 0
            }
            for index in 1..<line.points.count {
                let a = line.points[index - 1], b = line.points[index]
                guard let (near, far) = clip(screen(a), screen(b)) else {
                    flush(); touchedEnd = false; continue
                }
                let from = between(a, b, near), to = between(a, b, far)
                if !touchedEnd || near > 0 {
                    flush()
                    current = [from]
                }
                current.append(to)
                length += Double(hypot(to.x - from.x, to.y - from.y))
                touchedEnd = far >= 1
            }
            flush()
            return best
        }

        // Разбито на цикл, а не цепочку map/filter/sorted: цепочка с
        // кортежами не выводится компилятором за разумное время — он так и
        // говорит, и это уже второе такое место в проекте.
        struct Candidate {
            let line: Line
            let run: [CGPoint]
            let length: Double
        }
        let pointsPerMeter = viewHeight / spanMeters
        var ranked: [Candidate] = []
        for line in network where !line.name.isEmpty && line.points.count >= 2 {
            let run = visibleRun(line)
            guard run.count >= 2 else { continue }
            var total = 0.0
            for index in 1..<run.count {
                total += Double(hypot(run[index].x - run[index - 1].x,
                                      run[index].y - run[index - 1].y))
            }
            // Имя должно ВЛЕЗТЬ в видимый кусок: строка, торчащая за концы
            // улицы, читается как подпись к соседней. Порог длины в метрах
            // для этого не годится — на разных охватах одни и те же метры
            // занимают разное число пунктов.
            let needed = Double(line.name.count) * labelPointsPerCharacter * 1.15
            guard total * pointsPerMeter >= needed else { continue }
            ranked.append(Candidate(line: line, run: run, length: total))
        }
        // Порядок отбора — по классу, а не по близости: на перекрёстке
        // проспекта с проездом подписать надо проспект.
        ranked.sort {
            let left = RoadGeneralise.rank($0.line.kind)
            let right = RoadGeneralise.rank($1.line.kind)
            if left != right { return left < right }
            return $0.length > $1.length
        }

        var out: [Label] = []
        var placed: [CGPoint] = []
        for candidate in ranked {
            let line = candidate.line
            let run = candidate.run
            let length = candidate.length
            guard out.count < limit else { break }
            // Одна улица — одна подпись в кадре: склейка оставляет длинные
            // улицы целыми, но рядом бывает её же дублирующий кусок.
            guard !out.contains(where: { $0.text == line.name }) else { continue }
            // Середина берётся по ПРОЙДЕННОМУ ПУТИ, а не по номеру точки.
            //
            // После Дугласа — Пекера вершины лежат неравномерно: прямой
            // участок — одно звено, поворот — несколько подряд. Середина
            // индекса поэтому уезжает в поворот, а у прямой улицы, от которой
            // осталось две точки, попадает на КОНЕЦ — то есть подпись садится
            // в перекрёсток.
            var point = run[run.count - 1]
            var before = run[0]
            var after = point
            var walked = 0.0
            for index in 1..<run.count {
                let from = run[index - 1]
                let to = run[index]
                let step = Double(hypot(to.x - from.x, to.y - from.y))
                guard step > 0 else { continue }
                if walked + step >= length / 2 {
                    let share = CGFloat((length / 2 - walked) / step)
                    point = CGPoint(x: from.x + (to.x - from.x) * share,
                                    y: from.y + (to.y - from.y) * share)
                    // Угол — по СВОЕМУ звену: соседние вершины могут лежать за
                    // поворотом, и подпись легла бы поперёк улицы.
                    before = from
                    after = to
                    break
                }
                walked += step
            }
            // Расстояние между подписями меряется на ЭКРАНЕ: по горизонтали
            // доли ширины приводятся к долям высоты через aspect.
            let seat = screen(point)
            guard !placed.contains(where: {
                hypot(Double($0.x - seat.x) * aspect,
                      Double($0.y - seat.y)) < labelApartShare
            }) else { continue }
            var angle = atan2(Double(after.y - before.y),
                              Double(after.x - before.x)) * 180 / .pi
            // Экранный y растёт вниз, мир — вверх: знак угла обратный.
            angle = -angle
            // Вверх ногами не читается — доворачиваем на полкруга.
            if angle > 90 { angle -= 180 }
            if angle < -90 { angle += 180 }
            out.append(Label(text: line.name, point: point, angle: angle))
            placed.append(seat)
        }
        return out
    }

    static let farNetworkSpan: Double = 340

    /// Насколько широкой должна быть полоса НА ЭКРАНЕ, чтобы её разделительная
    /// что-то значила. Порога по охвату у разделительных нет и не нужно: полоса
    /// в метрах сама худеет с отдалением и уходит под этот порог там, где
    /// разметка перестаёт читаться. Шесть пунктов — граница, ниже которой
    /// пунктир превращается в рябь.
    static let laneDividerMinLanePoints: CGFloat = 6

    // MARK: - Краска на асфальте
    //
    // Размеры настоящие, в метрах: разметка обязана выглядеть тем же, чем она
    // является. Зебра в Узбекистане — четыре метра глубиной, полосы примерно
    // по полметра; стоп-линия — сорок сантиметров.

    /// Глубина зебры вдоль дороги, метры.
    static let zebraDepthMeters: CGFloat = 4
    /// Ширина одной полосы зебры и промежутка между ними, метры.
    static let zebraStripeMeters: CGFloat = 0.55
    /// …но не тоньше этого на экране.
    ///
    /// Полметра на охвате схемы — это полтора пункта, и сглаживание сливает
    /// такие полосы в ровное серое пятно: зебра перестаёт быть зеброй ровно
    /// там, где она нужна. Схема не фотография; когда честный размер уходит
    /// под порог различимости, читаемость старше масштаба — тем же правилом
    /// живёт ширина линий (zoomWidth) и толщина стоп-линии.
    static let zebraStripeMinPoints: CGFloat = 2.2
    /// Толщина стоп-линии, метры.
    static let stopLineMeters: CGFloat = 0.4
    /// Короче этого на экране разметка — сор в растре, а не черта.
    static let markingMinPoints: CGFloat = 12
    /// Длина стрелки полосы вдоль дороги, метры. Настоящая разметка длиннее
    /// (около пяти), но на схеме стрелка соседствует со стоп-линией и зеброй,
    /// и вытянутая перекрывала бы их.
    static let arrowMeters: CGFloat = 4.5

    /// Смещения разделительных от оси дороги, от края к центру.
    ///
    /// Правило простое и потому проверяемое: границы между полосами стоят
    /// через ширину полосы, а ось — посередине. У чётного числа полос одна из
    /// границ приходится ровно на ось; её здесь НЕТ намеренно — ось рисует
    /// свой проход, и смысл у неё другой (встречные потоки, а не попутные).
    ///
    /// Порядок — от края к центру, и это не косметика: рендерер кладёт полосы
    /// друг на друга, и широкая закрывает всё, что внутри неё.
    static func laneDividerOffsets(lanes: Int, laneWidth: CGFloat) -> [CGFloat] {
        guard lanes >= 3, laneWidth > 0 else { return [] }
        let half = CGFloat(lanes) / 2
        return stride(from: lanes - 1, through: 1, by: -1)
            .map { (CGFloat($0) - half) * laneWidth }
            .filter { $0 > 0 }
    }

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
        // Пол в сто метров писался под охват 140 и на виде вблизи означал
        // запас ВТРОЕ больше самого вида: растр раздувался до трёх с
        // половиной тысяч пунктов там, где видно пятьдесят пять метров.
        // Запас не бывает больше того, что он окружает.
        max(rebuildDriftFactor * span, min(100, span))
    }

    /// Радиус сцены: круг видимости при любом повороте (до дальнего угла
    /// вида, ~1.5 охвата с запасом на докрутку масштаба) плюс дрейф до
    /// пересборки.
    static func sceneRadius(forSpan span: Double) -> Double {
        span * 1.55 + driftMeters(forSpan: span)
    }

    // MARK: - Точка зрения (каждый тик, чистая арифметика)

    /// Сколько секунд дороги схема показывает впереди, когда тревожной камеры
    /// нет. Не метры, а секунды — по тому же принципу, что и «умный радиус»
    /// оповещений: на 60 км/ч сто сорок метров это восемь секунд, и схема
    /// упирается носом в асфальт вместо того, чтобы показать перекрёсток,
    /// к которому подъезжаешь. Двадцать секунд — это тот отрезок, на котором
    /// водитель ещё принимает решения.
    static let lookAheadSeconds: Double = 20

    /// Охват по дистанции до тревожной камеры: она должна попасть в верхнюю
    /// часть вида с запасом, а не упираться в край.
    ///
    /// Нижняя граница зависит от скорости: стоим — ближний план (там и смотреть
    /// нечего, кроме своей улицы), едем — вид отъезжает ровно настолько, чтобы
    /// в кадре был тот же отрезок времени. Иначе на трассе схема показывала
    /// пять секунд дороги, и по ней нельзя было понять даже, куда она ведёт.
    static func span(forDistance distance: Double?, speedKmh: Double = 0,
                     insets: Insets = .none) -> Double {
        let floorSpan = min(maxSpanMeters,
                            max(minSpanMeters, speedKmh / 3.6 * lookAheadSeconds))
        guard let distance else { return floorSpan }
        return min(maxSpanMeters, max(floorSpan, distance / reach(insets)))
    }

    /// Сколько высоты вида остаётся между «я» и местом камеры. Из него и
    /// считается охват: он и есть «во сколько раз охват больше дистанции».
    static func reach(_ insets: Insets) -> Double {
        max(0.1, insets.meY - insets.cameraY)
    }

    /// Камера в охвате вида. За охватом она не рисуется вовсе: показать её у
    /// края значило бы соврать масштабом, а дотянуть к ней дорогу — геометрией.
    ///
    /// «В охвате» означает буквально «попадает в видимый прямоугольник»: тот
    /// же расчёт, что у проекции, а не отдельная константа рядом с ней.
    static func isInRange(distance: Double, span: Double,
                          insets: Insets = .none) -> Bool {
        guard span > 0 else { return false }
        return insets.meY - distance / span >= insets.cameraEdgeY
    }

    /// Ступень масштаба ≤ охвата: растр выходит чуть детальнее, чем нужно,
    /// и scaleEffect только СЖИМАЕТ (резкость не теряется).
    ///
    /// Лестница начинается от охвата ВБЛИЗИ, а не от обычной нижней ступени.
    /// Пока она начиналась со 140 метров, вид вблизи (55 м) получал растр,
    /// нарисованный под 140, и scaleEffect РАСТЯГИВАЛ его в 2,55 раза: всё,
    /// ради чего вид вблизи заведён — разделительные, стоп-линия, зебра —
    /// рисовалось при шести пунктах на метр и увеличивалось втрое. Тест на
    /// ступени перебирал охваты от 140 и выше и этого не видел.
    static func bucket(forSpan span: Double) -> Double {
        let base = closeSpanMeters
        let steps = floor(log(span / base) / log(bucketRatio))
        return base * pow(bucketRatio, max(0, steps))
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
                            aspect: Double, insets: Insets = .none) -> CGPoint {
        let east = point.x - meOffset.x
        let north = point.y - meOffset.y
        // Знак положительный, и это не мелочь: точка по курсу обязана
        // оказаться строго ВВЕРХУ. С обратным знаком поворот давал
        // x = d·sin(2·курс) — на курсе 45° камера уезжала вбок, и дорога,
        // по которой едешь, рисовалась поперёк экрана.
        let angle = courseDegrees * .pi / 180
        let x = east * cos(angle) - north * sin(angle)
        let y = east * sin(angle) + north * cos(angle)
        return CGPoint(x: 0.5 + x / (spanMeters * aspect),
                       y: insets.meY - y / spanMeters)
    }

    // MARK: - Куски маршрута (стрелка манёвра и пройденное)

    /// Сколько метров маршрута ДО и ПОСЛЕ точки манёвра занимает стрелка.
    /// Не «столько-то пикселей»: стрелка обязана лежать на самой дороге, и
    /// её длина измеряется дорогой, а не экраном.
    static let maneuverLeadMeters: Double = 45
    static let maneuverTailMeters: Double = 45

    /// Дальше этого стрелку не рисуем. Манёвр за полкилометра — ещё не
    /// решение, а стрелка на весь экран впереди отвлекает от того, что рядом.
    static let maneuverVisibleMeters: Double = 500

    /// Сколько пройденного маршрута показываем позади. Дальше он всё равно за
    /// краем вида при любом охвате.
    static let passedVisibleMeters: Double = 800

    /// Окно стрелки манёвра по пути. nil — манёвра нет, он ещё далеко или уже
    /// пройден.
    static func maneuverWindow(stepAlong: Double,
                               progress: Double) -> (from: Double, to: Double)? {
        let remaining = stepAlong - progress
        guard remaining <= maneuverVisibleMeters,
              remaining > -maneuverTailMeters else { return nil }
        return (max(0, stepAlong - maneuverLeadMeters), stepAlong + maneuverTailMeters)
    }

    /// Кусок ломаной между двумя отметками пути, в МЕТРАХ относительно опоры
    /// сцены (восток, север) — в тех же координатах, что и вся сцена.
    ///
    /// Концы интерполируются: стрелка манёвра обязана начинаться там, где
    /// сказано, а не на ближайшей вершине — иначе на длинном прямом перегоне
    /// она начиналась бы за сотни метров до поворота.
    ///
    /// Отрезки до начала куска пропускаются без единого умножения сверх
    /// длины, а после конца цикл обрывается: метод зовётся на каждые 25 м
    /// пути, и на маршруте Ташкент—Бухара это разница между «дёшево» и
    /// «десять тысяч точек в секунду».
    static func subPath(_ coordinates: [CLLocationCoordinate2D],
                        from: CLLocationDistance, to: CLLocationDistance,
                        anchor: CLLocationCoordinate2D) -> [CGPoint] {
        guard coordinates.count >= 2, to > from else { return [] }
        let metersPerLon = 111_320.0 * cos(anchor.latitude * .pi / 180)
        func project(_ point: CLLocationCoordinate2D) -> CGPoint {
            CGPoint(x: (point.longitude - anchor.longitude) * metersPerLon,
                    y: (point.latitude - anchor.latitude) * 111_320.0)
        }
        func between(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D,
                     _ t: Double) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                   longitude: a.longitude + (b.longitude - a.longitude) * t)
        }

        var result: [CGPoint] = []
        var travelled: CLLocationDistance = 0
        for index in 1..<coordinates.count {
            let a = coordinates[index - 1], b = coordinates[index]
            let length = GeoMath.fastDistance(a.latitude, a.longitude,
                                              b.latitude, b.longitude)
            let segmentEnd = travelled + length
            if segmentEnd < from || length <= 0 { travelled = segmentEnd; continue }
            if travelled > to { break }
            if result.isEmpty {
                result.append(project(between(a, b, max(0, min(1, (from - travelled) / length)))))
            }
            if segmentEnd <= to {
                result.append(project(b))
            } else {
                result.append(project(between(a, b, max(0, min(1, (to - travelled) / length)))))
                break
            }
            travelled = segmentEnd
        }
        return result.count >= 2 ? result : []
    }

    /// Порядок слоёв местности снизу вверх.
    static func drawOrder(_ kind: SketchArea.Kind) -> Int {
        switch kind {
        case .block: return 0
        // Дом ложится НА квартал и под всё остальное: квартал закрывает
        // пустоту между улицами, дом — застройка внутри него. Ляг он ниже —
        // квартал закрасил бы застройку целиком.
        case .house: return 1
        case .green: return 2
        case .water: return 3
        case .rail:  return 4
        // Тротуар — САМЫМ ВЕРХНИМ из местности, но всё ещё под дорогами. Он
        // идёт вдоль проезжей части вплотную, и уйди он под зелень — пропал бы
        // ровно там, где нужен: вдоль улицы через парк.
        case .sidewalk: return 5
        // Поверхность — НАД местностью и ПОД сетью: это уже дорога, но линии
        // сети, разметка и обстановка ложатся на неё сверху.
        case .road: return 6
        // Перекрёсток последним из поверхности: он закрывает стыки полотен, и
        // лечь под них значило бы не закрыть ничего.
        case .junction: return 7
        // Разделительная — ПОВЕРХ перекрёстка и полотна: она их разрезает.
        // Ляг она ниже, асфальт закрасил бы её целиком.
        case .median: return 8
        }
    }

    // MARK: - Осмотр (панорама и зум)

    /// Сколько секунд бездействия до возврата к машине В ПОЕЗДКЕ.
    ///
    /// Шесть, а не десять и не «никогда». Дольше — и водитель успевает забыть,
    /// что смотрит не туда, где едет; экран, молча оставшийся не там, где
    /// машина, — самое опасное, что можно сделать за рулём.
    static let inspectReturnSeconds: Double = 6

    /// Через сколько секунд вид сам возвращается к машине. nil — не
    /// возвращается вовсе, и это не послабление правила, а его граница.
    ///
    /// Возврат существует ради ОДНОЙ опасности: за рулём экран не вправе
    /// молча остаться не там, где машина. На стоянке этой опасности нет —
    /// машина никуда не едет, а карта на экране и есть то, зачем её открыли.
    /// Отнимать её через шесть секунд значит запрещать смотреть: человек
    /// отодвинул вид на район, отвёл глаза прочитать адрес — и вернулся к
    /// своему перекрёстку.
    static func inspectReturn(isTripActive: Bool) -> Double? {
        isTripActive ? inspectReturnSeconds : nil
    }

    /// Потолок охвата ПРИ ОСМОТРЕ — отдельное число, а не `maxSpanMeters`.
    ///
    /// Тот отвечает на вопрос автоматики: дальше семисот метров схема
    /// перестаёт отвечать на «что впереди», и заводить туда точку зрения
    /// САМИМ было бы враньём про задачу. Осмотр — другой вопрос целиком:
    /// человек сам спросил «а что там дальше», и упирать его щипок в семьсот
    /// метров значит отвечать «не покажу». Двадцать километров — это область
    /// с окраинами: Ташкент по длинной стороне двадцать пять.
    static let inspectMaxSpanMeters: Double = 20_000

    /// Отменяет ли тревожная камера начатый осмотр.
    ///
    /// Отменяла ЛЮБАЯ камера в охвате, и на этом осмотр кончался вовсе.
    /// Камера стоит у перекрёстка, у перекрёстка же и стоят на светофоре —
    /// то есть `isInRange` истинно постоянно, а `returnToMe()` срабатывал на
    /// КАЖДОМ тике, раз в секунду. Проверено на снимке: до камеры 62 м, щипок
    /// и панорама не действуют ничем.
    ///
    /// Перебивать руку вправе только ПОДЪЕЗД: поездка идёт, машина едет,
    /// камера в охвате. Стоим — не вправе: смотреть карту на стоянке это
    /// ровно то, ради чего осмотр и заведён.
    static func alertInterruptsInspect(isTripActive: Bool, speedKmh: Double,
                                       alertInRange: Bool) -> Bool {
        alertInRange && isTripActive && speedKmh > closeSlowKmh
    }

    /// Экранный сдвиг пальца → метры сцены.
    ///
    /// Мир повёрнут по курсу, палец тянет по экрану — значит перевод требует
    /// обратного поворота. Формула выведена из screenPoint и обязана с ней
    /// совпадать: там точка сцены превращается в экранную, здесь наоборот.
    ///
    /// Знак отрицательный: палец тянет МИР, то есть центр вида уезжает в
    /// противоположную сторону.
    static func sceneOffset(fromScreen translation: CGSize,
                            courseDegrees: Double, spanMeters: Double,
                            viewHeight: CGFloat) -> CGSize {
        guard viewHeight > 0 else { return .zero }
        let metersPerPoint = spanMeters / Double(viewHeight)
        let u = Double(translation.width) * metersPerPoint
        let v = -Double(translation.height) * metersPerPoint
        let angle = courseDegrees * .pi / 180
        let east = u * cos(angle) + v * sin(angle)
        let north = -u * sin(angle) + v * cos(angle)
        return CGSize(width: -east, height: -north)
    }

    /// Точка сцены → экранная, в пунктах от «я». Обратная к sceneOffset и
    /// нужна ровно для одного: показать курсор там, где машина, когда вид
    /// уведён в сторону.
    static func screenOffset(fromScene offset: CGSize, courseDegrees: Double,
                             spanMeters: Double, viewHeight: CGFloat) -> CGSize {
        guard spanMeters > 0 else { return .zero }
        let pointsPerMeter = Double(viewHeight) / spanMeters
        let angle = courseDegrees * .pi / 180
        let east = Double(offset.width), north = Double(offset.height)
        let x = east * cos(angle) - north * sin(angle)
        let y = east * sin(angle) + north * cos(angle)
        return CGSize(width: x * pointsPerMeter, height: -y * pointsPerMeter)
    }

    /// Пора ли пересобирать растр: сменились данные или уехали от опоры.
    static func needsRebuild(scene: Scene?, key: RebuildKey, previousKey: RebuildKey?,
                             meOffsetMeters: CGPoint) -> Bool {
        guard let scene, key == previousKey else { return true }
        return hypot(meOffsetMeters.x, meOffsetMeters.y)
            > driftMeters(forSpan: scene.spanAtBuild)
    }

    /// Гейт неподвижности: сдвиг меньше шума GPS на стоянке и курс не повернул.
    /// Пороги — чуть выше типичного дрожания хорошего фикса (±1 м, ±1°):
    /// у большой карты тот же гейт стоит на 3 м/3°, у схемы масштаб крупнее
    /// и заметен раньше.
    static let standstillMeters = 2.0
    static let standstillDegrees = 2.0

    /// Нужно ли двигать точку зрения. Стоя на светофоре тик приходит каждую
    /// секунду, картинка не меняется, а запись смещения запускала анимацию и
    /// будила композитор — вхолостую, на самом дешёвом экране приложения.
    static func viewpointMoved(offsetDeltaMeters: Double, courseDeltaDegrees: Double,
                               spanChanged: Bool) -> Bool {
        spanChanged
            || offsetDeltaMeters >= standstillMeters
            || courseDeltaDegrees >= standstillDegrees
    }

    /// Деление линейки масштаба: круглое число, занимающее заметную, но не
    /// доминирующую часть вида.
    static func scaleBarMeters(forSpan span: Double) -> Double {
        // Лестница кончалась на пятистах метрах — ровно на потолке
        // автоматики. При осмотре, где охват доходит до двадцати километров,
        // линейка застревала на «500 м» и врала масштабом в сорок раз:
        // единственное на схеме, что связывает картинку с землёй, показывало
        // не то. Дальше километра шаг крупнее — читают её одним взглядом, а
        // не сравнивают деления.
        let candidates: [Double] = [50, 100, 200, 300, 500,
                                    1_000, 2_000, 5_000, 10_000]
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
                      precomputed: Bool = false,
                      areas: [SketchArea] = [],
                      areaBudget: Int = .max,
                      points: [SketchPoint] = [],
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
            return CameraDot(id: camera.id, point: point,
                             facing: camera.dir.map(Double.init),
                             axis: camera.axis.map(Double.init))
        }
        if alertInRange, let alertCamera {
            scene.alertCameraID = alertCamera.id
            if !scene.cameras.contains(where: { $0.id == alertCamera.id }) {
                scene.cameras.append(CameraDot(
                    id: alertCamera.id, point: local(alertCamera.coordinate),
                    facing: alertCamera.dir.map(Double.init),
                    axis: alertCamera.axis.map(Double.init)))
            }
        }

        // Точечные объекты: только те, что видны на этом охвате, и только в
        // круге сцены. Их немного по определению — перебор дешевле индекса.
        if !points.isEmpty {
            for mark in points where mark.kind.maxSpanMeters >= spanMeters {
                let point = local(mark.coordinate)
                guard hypot(point.x, point.y) <= radius else { continue }
                // Развилка по СЛОЮ, а не по виду: краска и значок рисуются
                // разными проходами и по-разному относятся к курсу.
                if mark.kind.isPaint, mark.widthMeters > 0 {
                    scene.markings.append(Marking(point: point, kind: mark.kind,
                                                  azimuthDegrees: mark.azimuthDegrees,
                                                  widthMeters: mark.widthMeters,
                                                  turns: mark.turns))
                } else if mark.kind.hasGlyph {
                    // Сюда попадает и краска без ширины: сервер не нашёл дороги
                    // под точкой, чертить нечем. Стоп-линия при этом остаётся
                    // видимой значком, как была до появления разметки, — объект,
                    // который раньше было видно, исчезать не должен.
                    scene.marks.append(Mark(point: point, kind: mark.kind))
                }
            }
        }

        // Местность: отбираем по рамке сцены и переводим в метры. Полигонов
        // здесь сотни против десятков тысяч дорог, поэтому перебор честнее
        // сеточного индекса — он стоил бы больше, чем экономит.
        if areaBudget > 0 && !areas.isEmpty {
            var kept: [Area] = []
            kept.reserveCapacity(min(areas.count, areaBudget))

            func clipped(_ area: SketchArea) -> Area? {
                let points = nearby(area.points)
                guard points.count >= (area.isClosed ? 3 : 2) else { return nil }
                return Area(points: points, kind: area.kind, isClosed: area.isClosed,
                            levels: area.levels, roadClass: area.roadClass)
            }

            // ПОЛОТНО — ОДНОЙ ПАЧКОЙ, прежде всего остального.
            //
            // Проезжая часть, площади перекрёстков и разделительные — это
            // одна фигура, разрезанная на файлы. Дорога без площади
            // перекрёстка — ленты, которые не сходятся; дорога, у которой
            // выброшен каждый пятый кусок, — рваная. Поэтому либо помещается
            // всё, либо не рисуется ничего, и тогда сеть чертится штрихом:
            // он дёшев, всегда непрерывен и сам закрывает узлы заглушками.
            //
            // Замерено на боевых тайлах в перегреве (бюджет 120): терялись
            // ВСЕ 41 площади перекрёстков и 20 из 82 кусков полотна — при том,
            // что очередь по maxSpanMeters пропускала вперёд воду, зелень и
            // кварталы. Слой, отвечающий на вопрос «где дорога», стоял в
            // очереди четвёртым.
            let pavement = areas
                .filter { $0.kind.isPavement && $0.kind.maxSpanMeters >= spanMeters }
                .compactMap(clipped)
            if !pavement.isEmpty && pavement.count <= areaBudget {
                kept = pavement
                scene.hasPavement = true
            }
            // Обход — ПО СЛОЯМ, а не по массиву.
            //
            // `areas` приезжает как flatMap по МНОЖЕСТВУ тайлов, то есть его
            // порядок — порядок хеша. Пока бюджет не заполняется, это никого
            // не трогает; как только заполняется — «первые N по порядку»
            // означает «кто выжил, решил хеш»: река исчезала бы через раз на
            // одном и том же месте, вытесненная пачкой домов из тайла,
            // который просто оказался раньше в обходе.
            //
            // Заполняться бюджет начнёт ровно тогда, когда поедут дома: их
            // 54 094 в одном кадре центра против четырёхсот мест в бюджете.
            //
            // Ключ приоритета — budgetRank, отдельное число. maxSpanMeters,
            // стоявший здесь раньше, отвечает на другой вопрос — «с какого
            // масштаба слой осмыслен», — и ключом бюджета ставил зелень
            // впереди проезжей части.
            let layers = SketchArea.Kind.allCases
                .filter { !$0.isPavement && $0.maxSpanMeters >= spanMeters }
                .sorted { $0.budgetRank < $1.budgetRank }
            layers: for layer in layers {
                for area in areas where area.kind == layer {
                    guard kept.count < areaBudget else { break layers }
                    guard let area = clipped(area) else { continue }
                    kept.append(area)
                }
            }
            // Вода поверх зелени, кварталы под всем: порядок задаётся здесь,
            // чтобы рендерер не сортировал на каждой пересборке.
            scene.areas = kept.sorted { drawOrder($0.kind) < drawOrder($1.kind) }
        }

        if networkBudget > 0 {
            let candidates = network
                .roads(near: anchor, radius: radius)
                .compactMap { line -> Line? in
                    guard line.points.count >= 2 else { return nil }
                    // За один проход: перевод в метры и рамка линии. Близость
                    // к машине здесь больше не считаем: она нужна только
                    // бюджету перегрева, и считать её надо ПОСЛЕ склейки —
                    // у куска geometry своей близости нет, есть у улицы.
                    var minX = CGFloat.infinity, maxX = -CGFloat.infinity
                    var minY = CGFloat.infinity, maxY = -CGFloat.infinity
                    let points = line.points.map { coordinate -> CGPoint in
                        let point = local(coordinate)
                        minX = min(minX, point.x); maxX = max(maxX, point.x)
                        minY = min(minY, point.y); maxY = max(maxY, point.y)
                        return point
                    }
                    // Линию целиком за квадратом растра незачем ни хранить,
                    // ни рисовать.
                    guard maxX >= -radius, minX <= radius,
                          maxY >= -radius, minY <= radius else { return nil }
                    return Line(points: points, kind: line.kind, level: line.level,
                                isOneWay: line.isOneWay, isDetailed: line.isDetailed,
                                isRing: line.isRing, lanes: line.lanes,
                                name: line.name)
                }
            // ГЕНЕРАЛИЗАЦИЯ — до бюджета, и порядок здесь важен дважды.
            //
            // Во-первых, склейка объединяет ways в непрерывные улицы, и после
            // неё «линий» становится в разы меньше — бюджет перегрева получает
            // осмысленные единицы вместо кусков геометрии. Во-вторых, отбор по
            // масштабу и отсев обрубков обязаны случиться ДО того, как бюджет
            // начнёт резать по близости: иначе в жару у машины оставались бы
            // ближние парковочные карманы, а проспект в трёхстах метрах
            // выпадал бы как дальний.
            //
            // Считаем на СОБРАННОМ охвате (spanAtBuild), а не на текущем:
            // растр живёт сотни метров и обязан быть согласован сам с собой.
            let generalised = RoadGeneralise.apply(candidates,
                                                   span: spanMeters,
                                                   onMinorRoad: showMinorRoads,
                                                   precomputed: precomputed)
            // Бюджет (даёт PerformanceMode): в перегрев остаются БЛИЖНИЕ линии.
            // Сеть — контекст, а не предупреждение: дорога камеры, маршрут и
            // трек не режутся ни на одной ступени, как и сами оповещения.
            let kept: [Line]
            if generalised.count <= networkBudget {
                kept = generalised
            } else {
                let byProximity = generalised.map { line -> (line: Line, near: Double) in
                    var near = Double.greatestFiniteMagnitude
                    for point in line.points {
                        near = min(near, max(abs(Double(point.x) - Double(meOffset.x)),
                                             abs(Double(point.y) - Double(meOffset.y))))
                    }
                    return (line, near)
                }
                kept = byProximity.sorted { $0.near < $1.near }
                    .prefix(networkBudget).map(\.line)
            }
            // Порядок отрисовки. Сначала земля, потом мосты — на это
            // рендерер полагается давно. Внутри уровня — от мелких к крупным,
            // и это новое: порядок там был произвольный, поэтому кайма
            // дворового проезда могла лечь поперёк проспекта и рассечь его
            // ровно на перекрёстке. Крупная дорога обязана быть сверху.
            scene.network = kept.sorted { first, second in
                first.level != second.level
                    ? first.level < second.level
                    : RoadGeneralise.rank(first.kind) > RoadGeneralise.rank(second.kind)
            }
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

        // Подписей в сцене нет: они зависят от точки зрения (что именно
        // видно сейчас), а сцена живёт сотни метров. Их считает состояние на
        // тике — по ТОЙ ЖЕ сети, что легла сюда, после генерализации и
        // бюджета.
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
