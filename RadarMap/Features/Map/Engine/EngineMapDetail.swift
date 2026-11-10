//
//  EngineMapDetail.swift
//  RadarMap
//
//  Наши значки «нужного сейчас» и цель в режиме прибытия (29.H): свой
//  источник и три слоя движка. Что рисовать решают MapDetailPolicy и
//  MapDetailPlaces; здесь — только слои и запись источника, и только на
//  СМЕНЕ набора (на тике ничего).
//
//  • `radar-detail-halo` — мягкий ореол точки цели (метры по земле, растёт
//    с масштабом, как дом под ним);
//  • `radar-detail-approach` — пунктир от конца маршрута к цели: где встать
//    и куда идти;
//  • `radar-detail-places` / `radar-detail-main` — заправки по пути, парковки
//    у цели, ближайшие из «По пути»: главная (ближайшая к цели парковка)
//    крупнее и места не уступает, остальные уступают подписям и камерам.
//
//  Слои — над маршрутом, под камерами: камера на карте важнее любого значка
//  и стоит в расстановке первой (слои приложения расставляются сверху вниз).
//

#if canImport(MapLibre)
import MapLibre
import UIKit

final class EngineMapDetail {

    static let sourceID = "radar-detail"
    static let targetSourceID = "radar-detail-target"
    static let placesLayer = "radar-detail-places"
    static let mainLayer = "radar-detail-main"
    static let haloLayer = "radar-detail-halo"
    static let approachLayer = "radar-detail-approach"

    /// Что лежит в источниках сейчас.
    struct Content: Equatable {
        var marks: [MapDetailPlaces.Mark] = []
        var halo: CLLocationCoordinate2D?
        var approach: [CLLocationCoordinate2D]?

        static func == (a: Content, b: Content) -> Bool {
            a.marks == b.marks && Self.same(a.halo, b.halo)
                && (a.approach?.count ?? 0) == (b.approach?.count ?? 0)
                && zip(a.approach ?? [], b.approach ?? []).allSatisfy { Self.same($0, $1) }
        }

        private static func same(_ a: CLLocationCoordinate2D?, _ b: CLLocationCoordinate2D?) -> Bool {
            switch (a, b) {
            case (nil, nil): true
            case let (a?, b?): a.latitude == b.latitude && a.longitude == b.longitude
            default: false
            }
        }
    }

    private var installed = false
    private var written: Content?
    private var paintedDaylight: Bool?

    /// Новый стиль: источников, слоёв и картинок нет — поставить заново.
    func styleLoaded() {
        installed = false
        written = nil
        paintedDaylight = nil
    }

    func update(_ content: Content, daylight: Bool, in view: MLNMapView) {
        guard let style = view.style else { return }
        if !installed { install(in: style) }
        if paintedDaylight != daylight {
            paintedDaylight = daylight
            let route = Theme.rgb(daylight ? RouteColors.body.day : RouteColors.body.night)
            if let halo = style.layer(withIdentifier: Self.haloLayer) as? MLNCircleStyleLayer {
                halo.circleColor = NSExpression(forConstantValue: route)
                halo.circleStrokeColor = NSExpression(forConstantValue: route)
            }
            (style.layer(withIdentifier: Self.approachLayer) as? MLNLineStyleLayer)?.lineColor =
                NSExpression(forConstantValue: route)
        }
        guard content != written else { return }
        written = content
        (style.source(withIdentifier: Self.sourceID) as? MLNShapeSource)?.shape =
            MLNShapeCollectionFeature(shapes: content.marks.map { mark in
                let point = MLNPointFeature()
                point.coordinate = mark.coordinate
                point.attributes = ["icon": Self.iconName(mark.kind), "rank": mark.rank]
                return point
            })
        var target: [MLNShape & MLNFeature] = []
        if let halo = content.halo {
            let point = MLNPointFeature()
            point.coordinate = halo
            point.attributes = ["role": "halo"]
            target.append(point)
        }
        if var line = content.approach, line.count >= 2 {
            let feature = MLNPolylineFeature(coordinates: &line, count: UInt(line.count))
            feature.attributes = ["role": "approach"]
            target.append(feature)
        }
        (style.source(withIdentifier: Self.targetSourceID) as? MLNShapeSource)?.shape =
            MLNShapeCollectionFeature(shapes: target)
    }

    static func iconName(_ kind: Venue.Kind) -> String { "radar-detail-\(kind.rawValue)" }

    private func install(in style: MLNStyle) {
        installed = true
        for kind in Venue.Kind.allCases where style.image(forName: Self.iconName(kind)) == nil {
            // Парковка — синяя, как дорожный знак; остальное — графит, как у
            // заправок слоя тайлов (EnginePlaceIcons): красный и цвета типов
            // на этой карте заняты камерами.
            let fill = Theme.rgb(kind == .parking ? MapIconColors.accentFill : MapIconColors.graphite)
            style.setImage(EnginePlaceIcons.icon(symbol: kind.symbol, fill: fill), forName: Self.iconName(kind))
        }
        let places = source(Self.sourceID, in: style)
        let target = source(Self.targetSourceID, in: style)
        // Над маршрутом, под камерами: первый из слоёв камер, что есть в стиле.
        let anchor = ["cng-status", "road-events", "camera-halo", "camera-dot", "camera-icons"].lazy
            .compactMap { style.layer(withIdentifier: $0) }.first

        func insert(_ layer: MLNStyleLayer) {
            guard style.layer(withIdentifier: layer.identifier) == nil else { return }
            if let anchor { style.insertLayer(layer, below: anchor) } else { style.addLayer(layer) }
        }

        let halo = MLNCircleStyleLayer(identifier: Self.haloLayer, source: target)
        halo.predicate = NSPredicate(format: "role == 'halo'")
        halo.circlePitchAlignment = NSExpression(forConstantValue: "map")
        halo.circleRadius = NSExpression(mglJSONObject: Self.metersExpression(AppConfig.mapDetailDestinationHaloMeters))
        halo.circleOpacity = NSExpression(forConstantValue: 0.16)
        halo.circleStrokeOpacity = NSExpression(forConstantValue: 0.7)
        halo.circleStrokeWidth = NSExpression(forConstantValue: 2)
        insert(halo)

        let approach = MLNLineStyleLayer(identifier: Self.approachLayer, source: target)
        approach.predicate = NSPredicate(format: "role == 'approach'")
        approach.lineWidth = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"], 14, 2, 18, 4])
        approach.lineDashPattern = NSExpression(forConstantValue: [1.2, 1.4])
        approach.lineCap = NSExpression(forConstantValue: "round")
        insert(approach)

        // Главная (ближайшая к цели парковка) — крупнее и места не уступает:
        // отдельным слоем, `icon-allow-overlap` у движка не зависит от данных.
        // Остальные уступают подписям улиц и камерам.
        for main in [false, true] {
            let symbols = MLNSymbolStyleLayer(identifier: main ? Self.mainLayer : Self.placesLayer, source: places)
            symbols.predicate = NSPredicate(format: main ? "rank == 0" : "rank > 0")
            symbols.iconImageName = NSExpression(forKeyPath: "icon")
            symbols.iconScale = NSExpression(mglJSONObject: ["match", ["get", "rank"], 0, 1.2, 1, 0.95, 0.8])
            symbols.iconAllowsOverlap = NSExpression(forConstantValue: main)
            symbols.iconPadding = NSExpression(forConstantValue: 2)
            symbols.iconPitchAlignment = NSExpression(forConstantValue: "viewport")
            insert(symbols)
        }
    }

    private func source(_ id: String, in style: MLNStyle) -> MLNShapeSource {
        if let existing = style.source(withIdentifier: id) as? MLNShapeSource { return existing }
        let source = MLNShapeSource(identifier: id, shape: nil)
        style.addSource(source)
        return source
    }

    /// Радиус в точках экрана для `meters` по земле у широты Ташкента: на z0
    /// метров на точку — 40 075 016·cos(41,3°)/512, дальше удваивается с уровнем.
    private static func metersExpression(_ meters: Double) -> [Any] {
        let perPointZ0 = 40_075_016.686 * cos(41.3 * .pi / 180) / 512
        let base = meters / perPointZ0
        return ["interpolate", ["exponential", 2], ["zoom"], 12, base * pow(2, 12), 22, base * pow(2, 22)]
    }
}
#endif
