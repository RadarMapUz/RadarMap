//
//  CarPlayShortcutLook.swift
//  RadarMap
//
//  Кнопки «Дом» и «Работа» на плитке главного экрана машины: как показать,
//  что нажатие дошло.
//
//  Владелец, 09.11: «Дом/Работа нажимаю, непонятно нажал ли, и внутри тоже».
//  У `CPDashboardButton` нет нажатого состояния и нет пути изменить показанную
//  кнопку — только новый массив `shortcutButtons` с другой подписью, поэтому
//  отклик — подпись. Значок должен быть статичным (заголовок SDK).
//
//  Чистая логика; CarPlayShortcutLookTests.
//

import CoreLocation
import Foundation

nonisolated enum CarPlayShortcutLook {

    enum Status: Equatable, Sendable {
        case idle
        case building(slow: Bool)
        case failed(RouteBuildFlow.Failure)
    }

    /// Что сейчас с маршрутом именно к этому месту. Заезд по пути и другая цель
    /// подпись кнопки не трогают.
    static func status(latitude: Double, longitude: Double, state: RouteBuildFlow.State) -> Status {
        let place = RouteBuildFlow.Target(name: "", latitude: latitude, longitude: longitude)
        switch state {
        case .working(let target, _, let slow) where target.isSame(as: place):
            return .building(slow: slow)
        case .failed(let target, let failure) where target.isSame(as: place):
            return .failed(failure)
        default:
            return .idle
        }
    }

    /// Ведём сюда уже сейчас: второе построение только сбросило бы ведение.
    static func isAlreadyGuiding(tripActive: Bool, destination: CLLocationCoordinate2D?,
                                 place: CLLocationCoordinate2D) -> Bool {
        guard tripActive, let destination else { return false }
        return GeoMath.fastDistance(destination.latitude, destination.longitude, place.latitude, place.longitude)
            < AppConfig.routeBuildSameTargetMeters
    }
}

/// Слова — на главном потоке: каталог знает язык приложения.
extension CarPlayShortcutLook.Status {
    /// Подпись кнопки, от длинной к короткой; nil — обычная подпись места.
    var subtitles: [String]? {
        switch self {
        case .idle:
            return nil
        case .building(false):
            return [String(localized: "Строим маршрут…")]
        case .building(true):
            return [String(localized: "Сеть медленная, ещё немного…"), String(localized: "Строим маршрут…")]
        case .failed(let failure):
            return [failure.shortTitle]
        }
    }
}

extension RouteBuildFlow.Failure {
    /// Причина в два слова — для подписи кнопки на плитке.
    var shortTitle: String {
        switch self {
        case .noFix:         return String(localized: "Нет GPS")
        case .network:       return String(localized: "Нет сети")
        case .noRoute:       return String(localized: "Нет маршрута")
        case .unavailable:   return String(localized: "Сервис недоступен")
        case .stopUnchanged: return String(localized: "Маршрут не построен")
        }
    }
}

extension RouteBuildFlow.State {
    /// Строка хода на приборе плитки; nil — построения нет.
    var gaugeLine: String? {
        switch self {
        case .idle:                      return nil
        case .working(_, _, slow: true): return String(localized: "Сеть медленная, ещё немного…")
        case .working:                   return String(localized: "Строим маршрут…")
        case .failed(_, let failure):    return failure.shortTitle
        }
    }
}
