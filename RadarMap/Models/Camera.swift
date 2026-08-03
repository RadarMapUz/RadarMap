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
enum CameraType: Hashable {
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

struct Camera: Identifiable, Codable, Hashable {
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

    init(id: Int, region: String, city: String, location: String,
         lat: Double, lon: Double, type: String, violations: [String],
         needsReview: Bool?, axis: Int? = nil) {
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

    // Равенство/хеш по id — координаты вычисляемые и в синтез не должны попадать.
    static func == (lhs: Camera, rhs: Camera) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
