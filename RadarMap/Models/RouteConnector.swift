//
//  RouteConnector.swift
//  RadarMap
//
//  Пунктир от машины до начала линии маршрута (70). OSRM начинает маршрут на
//  ближайшей дороге, а стоянка во дворе или GPS внутри здания оставляют машину
//  в десятках метров от неё: линия начиналась «ниоткуда». Пока машина не
//  выехала на маршрут — точки до места, куда она попадёт на линию.
//
//  Только картинка: ни прогресс маршрута, ни оповещения отсюда не читают.
//  Покрыто RouteConnectorTests.
//

import CoreLocation

nonisolated enum RouteConnector {

    /// Концы пунктира или nil: рядом с линией он спрятан под значком, в пути
    /// (срез ушёл вперёд) и за пределом расстояния не нужен.
    static func line(car: CLLocationCoordinate2D, target: CLLocationCoordinate2D,
                     cut: Double) -> [CLLocationCoordinate2D]? {
        guard cut <= AppConfig.routeConnectorAlongMeters else { return nil }
        let distance = GeoMath.fastDistance(car.latitude, car.longitude, target.latitude, target.longitude)
        guard distance >= AppConfig.routeConnectorMinMeters, distance <= AppConfig.routeConnectorMaxMeters else {
            return nil
        }
        return [car, target]
    }

    /// Запись в источник — только когда концы сдвинулись заметно или пунктир
    /// появился и исчез: шум стоянки источник не трогает.
    static func needsWrite(written: [CLLocationCoordinate2D]?, wanted: [CLLocationCoordinate2D]?) -> Bool {
        guard let written, let wanted, written.count == wanted.count else { return written != nil || wanted != nil }
        return zip(written, wanted).contains {
            GeoMath.fastDistance($0.latitude, $0.longitude, $1.latitude, $1.longitude)
                >= AppConfig.routeConnectorStepMeters
        }
    }
}
