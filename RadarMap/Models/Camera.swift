//
//  Camera.swift
//  RadarMap
//
//  Модель камеры видеофиксации (шаг 2).
//

import Foundation
import CoreLocation

/// Тип устройства фиксации. Строковое значение из PDF маппится в понятные категории,
/// неизвестные типы попадают в `.other`, чтобы приложение не падало на новых данных.
nonisolated enum CameraType: Hashable {
    case stationaryCamera   // «Стационар камера» — фиксирует все нарушения
    case stationaryRadar    // «Стационар радар» — только превышение скорости
    case intelligentRadar   // «Интеллектуал + радар» — новое поколение, фиксирует всё + скорость
    case mobileRadar        // «Передвижной радар» — краудсорсинг, живёт несколько часов
    case tripod             // «Тренога» — переносная камера на обочине (краудсорсинг)
    case dpsPost            // «Пост ДПС» (краудсорсинг)
    case accident           // «ДТП» (краудсорсинг, живёт ~час)
    case other(String)

    init(raw: String) {
        switch raw {
        case "Стационар камера", "Statsionar kamera":   self = .stationaryCamera
        case "Стационар радар", "Statsionar radar":     self = .stationaryRadar
        case "Интеллектуал + радар", "Intellektual + radar": self = .intelligentRadar
        case "Передвижной радар":                        self = .mobileRadar
        case "Тренога":                                  self = .tripod
        case "Пост ДПС":                                 self = .dpsPost
        case "ДТП":                                      self = .accident
        default:                                         self = .other(raw)
        }
    }

    /// Человекочитаемое название для UI.
    var displayName: String {
        switch self {
        case .stationaryCamera: return String(localized: "Стационарная камера")
        case .stationaryRadar:  return String(localized: "Стационарный радар")
        case .intelligentRadar: return String(localized: "Интеллектуальная камера + радар")
        case .mobileRadar:      return String(localized: "Передвижной радар")
        case .tripod:           return String(localized: "Тренога")
        case .dpsPost:          return String(localized: "Пост ДПС")
        case .accident:         return String(localized: "ДТП")
        case .other(let raw):   return raw
        }
    }

    /// Одно слово для короткого городского анонса: в городе камеры идут одна за
    /// другой, и «Стационарная камера впереди, 300 метров» на каждую — это уже
    /// не помощь, а болтовня. Тип в городе почти не меняет решение водителя.
    var shortName: String {
        switch self {
        case .stationaryCamera, .intelligentRadar: return String(localized: "Камера")
        case .stationaryRadar:                     return String(localized: "Радар")
        default:                                   return displayName
        }
    }

    /// Короткая фраза в родительном падеже для HUD («до камеры»).
    var genitivePhrase: String {
        switch self {
        case .stationaryCamera: return String(localized: "до камеры")
        case .stationaryRadar:  return String(localized: "до радара")
        case .intelligentRadar: return String(localized: "до камеры")
        case .mobileRadar:      return String(localized: "до передв. радара")
        case .tripod:           return String(localized: "до треноги")
        case .dpsPost:          return String(localized: "до поста ДПС")
        case .accident:         return String(localized: "до ДТП")
        case .other:            return String(localized: "до точки")
        }
    }

    /// Исходная строка типа (для записи в JSON своих камер).
    var sourceString: String {
        switch self {
        case .stationaryCamera: return "Стационар камера"
        case .stationaryRadar:  return "Стационар радар"
        case .intelligentRadar: return "Интеллектуал + радар"
        case .mobileRadar:      return "Передвижной радар"
        case .tripod:           return "Тренога"
        case .dpsPost:          return "Пост ДПС"
        case .accident:         return "ДТП"
        case .other(let raw):   return raw
        }
    }

    /// Внезапная точка: возникла только что, и знать о ней надо всегда —
    /// стационарную камеру на своей дороге водитель помнит, передвижной радар,
    /// треногу или ДТП — нет. Такие никогда не глушим и даём им более широкий
    /// коридор: координата пришла из краудсорса и точна хуже реестровой.
    var isSudden: Bool {
        switch self {
        case .mobileRadar, .tripod, .accident: return true
        default:                               return false
        }
    }

    /// SF Symbol для аннотации на карте.
    var symbolName: String {
        switch self {
        case .stationaryCamera: return "camera.fill"
        case .stationaryRadar:  return "speedometer"
        case .intelligentRadar: return "camera.metering.matrix"
        case .mobileRadar:      return "dot.radiowaves.left.and.right"
        case .tripod:           return "camera.metering.spot"
        case .dpsPost:          return "shield.lefthalf.filled"
        case .accident:         return "exclamationmark.triangle.fill"
        case .other:            return "mappin"
        }
    }
}

/// `nonisolated` — камеры перебирает геометрия маршрута и грид-индекс вне main.
nonisolated struct Camera: Identifiable, Codable, Hashable {
    let id: Int
    let region: String
    let city: String
    let location: String
    let lat: Double
    let lon: Double
    let type: String
    let violations: [String]
    /// `true`, если координаты восстановлены приблизительно (битые данные в исходном PDF).
    let needsReview: Bool?
    /// Ось дороги камеры (0–179°, недирекционная), проставляется снапом.
    /// Курс поперёк оси = едем НАД камерой (мост) или по перпендикулярной
    /// улице развязки — такую камеру не алертим и проезд не считаем.
    let axis: Int?
    /// Направление проезжей части (0–359°) — ТОЛЬКО у односторонних дорог, где
    /// OSM знает его однозначно (у разделённой дороги каждая сторона — своя
    /// линия). Есть направление — камера обратной стороны перестаёт быть нашей.
    /// У двусторонней улицы его нет: куда смотрит камера, не знает никто.
    let dir: Int?
    /// Полос на дороге по тегу OSM — из них считается ширина коридора вместо
    /// одной константы на весь город.
    let lanes: Int?
    /// Класс дороги OSM («primary», «residential», …): мгновенный контекст
    /// «город или трасса», не дожидаясь трёх минут детектора.
    let cls: String?
    /// Камера на мосту или эстакаде — второй признак к эвристике по оси.
    let bridge: Bool?
    /// Кусок проезжей части вокруг камеры: пары дельт (lat, lon) в 1e-6°
    /// от координаты камеры. По нему считается настоящее «я на этой дороге».
    let road: [Int]?
    /// Дорога разделённая: рядом идёт параллельная проезжая часть обратного
    /// направления. Значит по обратной стороне реально едут — и одиночная
    /// камера может снимать её тоже.
    let split: Bool?
    /// Рядом стоит камера обратного направления: стороны дороги поделены между
    /// двумя камерами, каждая смотрит свою.
    let twin: Bool?

    /// Стороны дороги ДОКАЗАННО поделены — только тогда геометрии можно глушить
    /// камеру за то, что мы едем по обратной проезжей части.
    ///
    /// Доказательство одно из двух: рядом стоит парная камера обратного
    /// направления (каждая смотрит свою сторону) либо дорога заведомо не
    /// разделена — тогда обратной проезжей части просто не существует.
    ///
    /// Без доказательства камера вполне может снимать И обратную сторону, и
    /// молчание про неё хуже лишнего предупреждения. Отсутствие признаков
    /// (старая база) — это тоже «не доказано»: неизвестность трактуем в пользу
    /// предупреждения. Таких камер половина базы, поэтому это главный
    /// предохранитель против пропусков.
    var sidesAreProven: Bool {
        guard hasTrustedRoadProfile else { return false }
        if twin == true { return true }
        return split == false
    }

    /// Профилю дороги можно верить: снап нашёл именно проезжую часть. У части
    /// камер он сел на тротуар, переход или платформу (в базе v10 таких 39) —
    /// это ошибка сопоставления, и ни направление такой «дороги», ни её
    /// геометрия к движению машин отношения не имеют. Глушить по ним нельзя:
    /// пешеходный переход идёт ПОПЕРЁК проезжей части, и камера над дорогой
    /// выглядела бы для гейта оси как камера на перпендикулярной улице.
    var hasTrustedRoadProfile: Bool { roadClass.isVehicleRoad }

    /// Можно ли отбрасывать камеру по НАПРАВЛЕНИЮ движения: нужно и само
    /// направление проезжей части, и доказательство, что стороны поделены.
    var allowsDirectionGate: Bool { dir != nil && sidesAreProven }

    /// Направление для клина на маркере карты; nil — рисуем круг.
    /// Условие то же, что у гейта: нарисовать стрелку камере, чьё направление
    /// база доказать не может, значило бы соврать — она вполне снимает обе
    /// стороны. Одно правило на карту телефона и на карту машины.
    var markerDirection: Int? { allowsDirectionGate ? dir : nil }

    /// Класс дороги в разобранном виде.
    var roadClass: RoadClass { RoadClass(raw: cls) }

    init(id: Int, region: String, city: String, location: String,
         lat: Double, lon: Double, type: String, violations: [String],
         needsReview: Bool?, axis: Int? = nil, dir: Int? = nil,
         lanes: Int? = nil, cls: String? = nil, bridge: Bool? = nil,
         road: [Int]? = nil, split: Bool? = nil, twin: Bool? = nil) {
        self.dir = dir
        self.lanes = lanes
        self.cls = cls
        self.bridge = bridge
        self.road = road
        self.split = split
        self.twin = twin
        self.id = id
        self.region = region
        self.city = city
        self.location = location
        self.lat = lat
        self.lon = lon
        self.type = type
        self.violations = violations
        self.needsReview = needsReview
        self.axis = axis
    }

    /// В bundled-JSON поле `violations` опущено (на 100% определяется типом) —
    /// восстанавливаем из типа. Общие статические массивы = одна копия в памяти на все камеры.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        region = try c.decode(String.self, forKey: .region)
        city = try c.decode(String.self, forKey: .city)
        location = try c.decode(String.self, forKey: .location)
        lat = try c.decode(Double.self, forKey: .lat)
        lon = try c.decode(Double.self, forKey: .lon)
        type = try c.decode(String.self, forKey: .type)
        needsReview = try c.decodeIfPresent(Bool.self, forKey: .needsReview)
        axis = try c.decodeIfPresent(Int.self, forKey: .axis)
        dir = try c.decodeIfPresent(Int.self, forKey: .dir)
        lanes = try c.decodeIfPresent(Int.self, forKey: .lanes)
        cls = try c.decodeIfPresent(String.self, forKey: .cls)
        bridge = try c.decodeIfPresent(Bool.self, forKey: .bridge)
        road = try c.decodeIfPresent([Int].self, forKey: .road)
        split = try c.decodeIfPresent(Bool.self, forKey: .split)
        twin = try c.decodeIfPresent(Bool.self, forKey: .twin)
        violations = try c.decodeIfPresent([String].self, forKey: .violations)
            ?? Self.defaultViolations(forType: type)
    }

    static let standardViolations = [
        "йўл белгилари", "хавфсизлик камаридан фойдаланиш", "тезликни ошириш",
        "қизил чироқда бўйсунмасдан ўтиш", "қарама қарши йўналишда ҳаракатланиш",
        "тўхташ қоидаларини бузиш", "тўхтаб туриш қоидаларини бузиш",
        "қизил чироқда тўхташ чизиғини босиб кириш",
    ]
    static let radarViolations = ["тезликни ошириш"]

    /// Сырые строки нарушений в базе — узбекская кириллица из egov; в UI показываем
    /// на языке интерфейса. Неизвестные строки оставляем как есть (лучше сырое, чем ничего).
    nonisolated static func localizedViolation(_ raw: String) -> String {
        switch raw.lowercased() {
        case "тезликни ошириш":
            return String(localized: "Превышение скорости")
        case "йўл белгилари":
            return String(localized: "Дорожные знаки и разметка")
        case "хавфсизлик камаридан фойдаланиш":
            return String(localized: "Ремень безопасности")
        case "қизил чироқда бўйсунмасдан ўтиш":
            return String(localized: "Проезд на красный")
        case "қарама қарши йўналишда ҳаракатланиш":
            return String(localized: "Выезд на встречную полосу")
        case "тўхташ қоидаларини бузиш":
            return String(localized: "Нарушение правил остановки")
        case "тўхтаб туриш қоидаларини бузиш":
            return String(localized: "Нарушение правил стоянки")
        case "қизил чироқда тўхташ чизиғини босиб кириш":
            return String(localized: "Заезд за стоп-линию")
        default:
            return raw
        }
    }

    /// Нарушения на языке интерфейса — для карточки камеры и уведомлений.
    var localizedViolations: [String] { violations.map(Self.localizedViolation) }

    static func defaultViolations(forType type: String) -> [String] {
        switch CameraType(raw: type) {
        case .stationaryCamera, .intelligentRadar: return standardViolations
        case .stationaryRadar, .mobileRadar, .tripod: return radarViolations
        case .dpsPost, .accident, .other:          return []
        }
    }

    // MARK: - Вычисляемые свойства

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var kind: CameraType { CameraType(raw: type) }

    /// Заголовок для маркера/попапа: адрес, иначе город, иначе регион.
    var displayTitle: String {
        if !location.isEmpty { return location }
        if !city.isEmpty { return city }
        return region
    }

    /// Подзаголовок «Город, Регион».
    var subtitle: String {
        [city, region].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    var isApproximate: Bool { needsReview == true }

    /// Расстояние в метрах от заданной координаты до камеры.
    func distance(from coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            .distance(from: CLLocation(latitude: lat, longitude: lon))
    }

    // MARK: - Правки модератора (CameraOverride)

    /// Камера с исправленной координатой.
    ///
    /// Весь профиль дороги при этом сбрасывается: `axis`, `dir`, `road`,
    /// `split`, `twin`, `bridge`, `cls`, `lanes` снап измерил В ДРУГОЙ ТОЧКЕ, и
    /// после переноса они описывают чужую дорогу. Особенно `road` — это дельты
    /// ОТ координаты камеры, так что вместе с ней уехала бы и «проезжая часть».
    ///
    /// Цена сброса — камера перестаёт глушиться по направлению и оси, то есть
    /// предупреждает чаще. Это ровно та сторона, в которую здесь ошибаться
    /// можно: лишнее предупреждение дешевле молчания.
    func moved(lat: Double, lon: Double) -> Camera {
        Camera(id: id, region: region, city: city, location: location,
               lat: lat, lon: lon, type: type, violations: violations,
               needsReview: needsReview)
    }

    /// Камера с исправленным типом. Нарушения выводятся из типа, поэтому
    /// пересобираются: иначе «радар» остался бы со списком нарушений камеры.
    func retyped(to newType: String) -> Camera {
        Camera(id: id, region: region, city: city, location: location,
               lat: lat, lon: lon, type: newType,
               violations: Self.defaultViolations(forType: newType),
               needsReview: needsReview, axis: axis, dir: dir, lanes: lanes,
               cls: cls, bridge: bridge, road: road, split: split, twin: twin)
    }

    // Равенство/хеш по id — координаты вычисляемые и в синтез не должны попадать.
    static func == (lhs: Camera, rhs: Camera) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
