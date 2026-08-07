//
//  CameraOverride.swift
//  RadarMap
//
//  Правки базы камер, принятые модератором: подписанный журнал поверх
//  cameras.json вместо выкатки мегабайта ради одной строки.
//
//  Зачем отдельным файлом, а не новой версией базы:
//    • 2 КБ против 1 МБ — публиковать можно хоть каждый день, и трафик
//      пользователей от этого не страдает;
//    • база остаётся стабильной и воспроизводимой (её всегда можно пересобрать
//      из update_cameras.py + snap_cameras.py), а ручные решения живут отдельным
//      списком, который читается глазами;
//    • откат — это удалить строку и опубликовать заново, секунды вместо получаса.
//
//  Подпись — та же Ed25519 и тот же fail closed: не сошлась, не разобралось,
//  выглядит неправдоподобно — правки не применяются вовсе, работаем на базе.
//  Ошибиться здесь дороже, чем в любом другом файле: скрытие камеры производит
//  МОЛЧАНИЕ там, где камера стоит, а это худший отказ всей системы.
//

import CoreLocation
import Foundation

nonisolated struct CameraOverride: Codable, Equatable, Sendable {
    enum Operation: String, Codable, Sendable {
        case hide      // камеры больше нет — убрать с карты и из оповещений
        case move      // координата неверная — поправить
        case retype    // тип определён неверно (например, «камера» вместо «радар»)
    }

    let id: Int
    let op: Operation
    var lat: Double?
    var lon: Double?
    /// Строка типа в том же виде, в каком она лежит в базе (`Camera.type`).
    var type: String?
}

/// Опубликованный снимок действующих правок. Именно снимок, а не приращение:
/// «отменить» — это опубликовать файл без этой строки, и тогда состояние всегда
/// читается целиком, без разбора истории.
nonisolated struct CameraOverrides: Codable, Equatable, Sendable {
    var version: Int
    var updatedAt: String?
    var items: [CameraOverride]

    static let empty = CameraOverrides(version: 0, updatedAt: nil, items: [])
}

typealias CameraOverridesEnvelope = SignedPayload<CameraOverrides>

/// Применение правок к базе. Отдельный `nonisolated enum`, а не метод стора:
/// чистая функция от списка камер и списка правок — её можно проверить тестом
/// целиком, что для кода, умеющего гасить оповещения, обязательно.
nonisolated enum CameraOverrideEngine {

    /// Результат применения: новый список камер и что именно сделали.
    struct Result: Equatable {
        var cameras: [Camera]
        var hidden: Int
        var moved: Int
        var retyped: Int
        /// Правки, которые мы отвергли как неправдоподобные (см. `sanityCheck`).
        var rejected: Int
    }

    /// Применить правки к базовому списку.
    ///
    /// Правки бьют ТОЛЬКО по базе. Свои камеры пользователя — его дело, а
    /// передвижные модерируются на сервере напрямую (там правка мгновенна и
    /// подписи не требует), так что лезть в них отсюда незачем.
    static func apply(_ overrides: CameraOverrides, to cameras: [Camera]) -> Result {
        guard !overrides.items.isEmpty else {
            return Result(cameras: cameras, hidden: 0, moved: 0, retyped: 0, rejected: 0)
        }
        var byID: [Int: CameraOverride] = [:]
        byID.reserveCapacity(overrides.items.count)
        // Последняя правка для id побеждает: файл собирает админка, дубли в нём
        // не ожидаются, но молча применять две противоречивые нельзя.
        for item in overrides.items { byID[item.id] = item }

        var result: [Camera] = []
        result.reserveCapacity(cameras.count)
        var hidden = 0, moved = 0, retyped = 0, rejected = 0

        for camera in cameras {
            guard let override = byID[camera.id] else {
                result.append(camera)
                continue
            }
            switch override.op {
            case .hide:
                hidden += 1
            case .move:
                guard let lat = override.lat, let lon = override.lon,
                      isPlausibleMove(from: camera, toLat: lat, lon: lon) else {
                    rejected += 1
                    result.append(camera)   // сомнительную правку не применяем, камеру не теряем
                    continue
                }
                result.append(camera.moved(lat: lat, lon: lon))
                moved += 1
            case .retype:
                guard let type = override.type, !type.isEmpty else {
                    rejected += 1
                    result.append(camera)
                    continue
                }
                result.append(camera.retyped(to: type))
                retyped += 1
            }
        }
        return Result(cameras: result, hidden: hidden, moved: moved,
                      retyped: retyped, rejected: rejected)
    }

    /// Правдоподобен ли файл целиком.
    ///
    /// Предохранитель от ошибки в админке или в скрипте публикации, а не от
    /// злоумышленника (от него защищает подпись). Правка базы — единственная
    /// операция, способная сделать приложение молчаливым, и файл, скрывающий
    /// сотни камер разом, гораздо вероятнее является опечаткой в SQL, чем
    /// решением модератора. Такому файлу мы не верим целиком: лучше остаться
    /// на устаревшей базе, чем поехать без половины предупреждений.
    static func isSane(_ overrides: CameraOverrides, baseCount: Int) -> Bool {
        guard baseCount > 0 else { return false }
        let hides = overrides.items.count { $0.op == .hide }
        return Double(hides) <= Double(baseCount) * AppConfig.overrideMaxHiddenShare
    }

    private static func isPlausibleMove(from camera: Camera,
                                        toLat lat: Double, lon: Double) -> Bool {
        guard AppConfig.uzLatRange.contains(lat), AppConfig.uzLonRange.contains(lon) else {
            return false
        }
        // Поправка снапа — это десятки метров. Километры означают, что кто-то
        // перепутал камеру или запятую в координате, а «переехавшая» камера
        // молчит на своём месте ровно так же, как скрытая.
        return GeoMath.fastDistance(camera.lat, camera.lon, lat, lon)
            <= AppConfig.overrideMaxMoveMeters
    }
}
