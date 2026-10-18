// Сверка черновиков на нашей карте. Не влияет на навигационные данные.
// Только отладочная сборка: в релиз экран, слой и их строки не попадают.
#if DEBUG && canImport(MapLibre)
import SwiftUI
import MapLibre
import CoreLocation
import os

struct RoadPilotPreview: View {
    @State private var selected = 0
    @State private var visible = true
    @State private var opacity = 0.7

    var body: some View {
        let frame = RoadPilotFrame.all[selected]
        VStack(spacing: 8) {
            if frame.referenceAligned {
                Text("Совмещено с осями · точность полос не подтверждена")
                    .font(.headline).foregroundStyle(.orange)
            } else {
                Text("Коррекция отклонена · исходная привязка")
                    .font(.headline).foregroundStyle(.red)
            }
            Text("Голубой — полотно, розовый — кандидаты разметки. Это алгоритм по цвету, не обученная ML-модель.")
                .font(.caption).padding(.horizontal)
            Picker("Снимок", selection: $selected) {
                ForEach(RoadPilotFrame.all) { item in
                    Text("Кадр \(item.id + 1)").tag(item.id)
                }
            }
            if frame.empty {
                Text("На этом кадре алгоритм пропустил дороги.")
                    .font(.caption).foregroundStyle(.orange)
            }
            EngineMapView(
                coordinate: CLLocationCoordinate2D(latitude: frame.latitude, longitude: frame.longitude),
                courseDegrees: -1, spanMeters: 350, anchorY: 0.5,
                pitchDegrees: 0, daylight: true, houses: true,
                cameras: [], route: [], recenterToken: selected,
                modernStyle: true, northUp: true,
                roadPilot: visible ? frame : nil, roadPilotOpacity: opacity
            )
            HStack {
                Toggle("Черновой слой", isOn: $visible)
                Slider(value: $opacity, in: 0...1)
                    .accessibilityLabel(Text("Прозрачность слоя"))
            }.padding(.horizontal)
            Text("Источник снимков: Яндекс Карты. Геометрия и типы линий не подтверждены.")
                .font(.caption2).padding(.horizontal)
        }
        .navigationTitle("Пилот дорог")
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum RoadPilotOverlay {
    private static let sourceID = "road-pilot-preview-source"
    private static let layerID = "road-pilot-preview-layer"

    static func apply(_ frame: RoadPilotFrame?, opacity: Double, to style: MLNStyle) {
        guard let frame else {
            if let layer = style.layer(withIdentifier: layerID) { style.removeLayer(layer) }
            if let source = style.source(withIdentifier: sourceID) { style.removeSource(source) }
            return
        }
        guard let url = Bundle.main.url(forResource: frame.imageName, withExtension: "png") else {
            Log.network.error("Пилот дорог: ресурс отсутствует \(frame.imageName, privacy: .public)")
            return
        }
        let current = style.source(withIdentifier: sourceID) as? MLNImageSource
        if current?.url != url {
            if let layer = style.layer(withIdentifier: layerID) { style.removeLayer(layer) }
            if let source = current { style.removeSource(source) }
            let quad = MLNCoordinateQuad(
                topLeft: .init(latitude: frame.north, longitude: frame.west),
                bottomLeft: .init(latitude: frame.south, longitude: frame.west),
                bottomRight: .init(latitude: frame.south, longitude: frame.east),
                topRight: .init(latitude: frame.north, longitude: frame.east))
            let source = MLNImageSource(identifier: sourceID, coordinateQuad: quad, url: url)
            style.addSource(source)
            style.addLayer(MLNRasterStyleLayer(identifier: layerID, source: source))
        }
        (style.layer(withIdentifier: layerID) as? MLNRasterStyleLayer)?.rasterOpacity = NSExpression(forConstantValue: opacity)
    }
}
#endif
