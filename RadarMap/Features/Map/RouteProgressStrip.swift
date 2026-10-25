//
//  RouteProgressStrip.swift
//  RadarMap
//
//  Полоса хода маршрута в нижней панели поездки (29.G, как у Яндекса):
//  слева старт, справа финиш, треугольник «я», отрезки цветом пробок, точки
//  камер маршрута. До 29.G она стояла вертикально у правого края (29.B, как
//  у Amap) — в щели между колонкой кнопок и нижней панелью: на SE щель
//  уже 120 pt, и полоса пропадала ровно там, где экран меньше всего; спорила
//  с кнопками и с камерами у правого края карты. В панели она есть всегда,
//  стоит 10 pt высоты и читается слева направо, как время.
//
//  Раскладку считает RouteProgressBar вне главного потока — раз на маршрут и
//  на новые пробки. Прогресс маршрута меняется на каждом фиксе, поэтому его
//  читает только эта маленькая вью (ARCHITECTURE, правило 13), а сама полоса
//  перерисовывается, лишь когда отметка «я» сдвинулась на пункт.
//

import CoreLocation
import MapKit
import SwiftUI

/// Раскладка полосы для текущего маршрута — состояние экрана, не вью.
@MainActor
@Observable
final class RouteStripState {
    nonisolated deinit {}

    private(set) var layout: RouteProgressBar.Layout = .empty
    @ObservationIgnored private var generation = 0

    /// Новый маршрут, пробки или камеры: пересчитать вне главного потока.
    func refresh(route: [MKMapPoint], snapshot: TrafficSnapshot?,
                 cameras: [RouteProgressBar.CameraInput]) async {
        generation += 1
        let token = generation
        let fresh = await Self.build(route: route, snapshot: snapshot, cameras: cameras)
        guard token == generation, fresh != layout else { return }
        layout = fresh
    }

    func clear() {
        generation += 1
        if layout != .empty { layout = .empty }
    }

    @concurrent
    private static func build(route: [MKMapPoint], snapshot: TrafficSnapshot?,
                              cameras: [RouteProgressBar.CameraInput]) async -> RouteProgressBar.Layout {
        RouteProgressBar.build(route: route.map(\.coordinate), cumulative: RouteService.cumulative(of: route),
                               snapshot: snapshot, cameras: cameras,
                               minGap: 0)
    }
}

/// Читает прогресс маршрута (тик) и держит раскладку полосы.
struct RouteProgressStripGate: View {
    @Environment(AppEnvironment.self) private var env
    @State private var state = RouteStripState()
    @State private var width: CGFloat = 0

    /// Ключ пересчёта раскладки: маршрут (объект полилайна), пробки, камеры.
    private struct Key: Equatable {
        var route: ObjectIdentifier?
        var traffic: Int
        var cameras: Int
    }

    var body: some View {
        let key = Key(route: env.route.polyline.map(ObjectIdentifier.init),
                      traffic: env.traffic.revision * 2 + (env.traffic.isShown ? 1 : 0),
                      cameras: env.route.camerasOnRoute.count)
        let progress = RouteProgressBar.fraction(progress: env.route.progressAlong, length: state.layout.length)
        RouteProgressStrip(layout: state.layout,
                           progress: RouteProgressBar.step(progress, height: Double(width),
                                                           points: AppConfig.routeStripStepPoints),
                           width: Double(width))
            .equatable()
            .frame(maxWidth: .infinity)
            .frame(height: AppConfig.routeStripHeight)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .task(id: key) {
                guard key.route != nil, let variant = env.route.selected else {
                    state.clear()
                    return
                }
                let cameras = variant.cameras.filter(\.countsAsOurs).map {
                    RouteProgressBar.CameraInput(id: $0.camera.id, along: $0.distanceAlong, kind: $0.camera.kind)
                }
                await state.refresh(route: variant.points,
                                    snapshot: env.traffic.isShown ? env.traffic.snapshot : nil,
                                    cameras: cameras)
            }
    }
}

/// Сама полоса: шкала, отрезки, камеры, «я». Equatable — перерисовка только
/// на смене раскладки или шага отметки.
struct RouteProgressStrip: View, Equatable {
    let layout: RouteProgressBar.Layout
    /// Доля пройденного, уже округлённая до шага.
    let progress: Double
    let width: Double

    private var track: CGFloat { AppConfig.routeStripTrackHeight }

    var body: some View {
        let w = CGFloat(width)
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Self.colour(.unknown))
                .frame(width: w, height: track)
            ForEach(Array(layout.segments.enumerated()), id: \.offset) { _, segment in
                Rectangle()
                    .fill(Self.colour(segment.tone))
                    .frame(width: max(0, CGFloat(segment.to - segment.from) * w), height: track)
                    .offset(x: CGFloat(segment.from) * w)
            }
            // Пройденное — приглушено поверх: уже не решение, а память.
            Rectangle()
                .fill(Theme.surface.opacity(0.62))
                .frame(width: CGFloat(progress) * w, height: track)
            ForEach(RouteProgressBar.thinned(layout.cameras,
                                             minGap: Double(AppConfig.routeStripCameraSize) / max(1, width)),
                    id: \.id) { mark in
                Circle()
                    .fill(Color(uiColor: Theme.rgb(Self.cameraHex(mark.kind))))
                    .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                    .frame(width: AppConfig.routeStripCameraSize, height: AppConfig.routeStripCameraSize)
                    .opacity(mark.fraction < progress ? 0.45 : 1)
                    .offset(x: CGFloat(mark.fraction) * w - AppConfig.routeStripCameraSize / 2)
            }
            // «Я» — треугольник носом по ходу, как у Яндекса: точка на шкале
            // читалась бы ещё одной камерой.
            MeTriangle()
                .fill(Theme.accentFill)
                .overlay(MeTriangle().stroke(.white, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)))
                .frame(width: AppConfig.routeStripMeSize, height: AppConfig.routeStripMeSize)
                .offset(x: CGFloat(progress) * w - AppConfig.routeStripMeSize / 2)
        }
        .frame(width: w, height: AppConfig.routeStripHeight, alignment: .leading)
        .accessibilityElement()
        .accessibilityLabel(Text("Ход маршрута"))
        .accessibilityValue(Text(String(format: String(localized: "Пройдено %lld %%"), Int((progress * 100).rounded()))))
    }

    /// Цвета пробок — те же, что слой пробок и линия маршрута (RouteColors);
    /// «нет данных» — нейтральный серый, не зелёный.
    static func colour(_ tone: RouteProgressBar.Tone) -> Color {
        switch tone {
        case .unknown: return Theme.adaptive(0xC9CED6, 0x4A505B)
        case .free:    return Theme.adaptive(RouteColors.free.day, RouteColors.free.night)
        case .slow:    return Theme.adaptive(RouteColors.slow.day, RouteColors.slow.night)
        case .jam:     return Theme.adaptive(RouteColors.jam.day, RouteColors.jam.night)
        }
    }

    /// Цвет типа камеры — тот же, что у значков карты (EngineMapStyle.typeHex).
    private static func cameraHex(_ kind: CameraType) -> UInt32 {
        UInt32(EngineMapStyle.typeHex(kind).dropFirst(), radix: 16) ?? 0x6B6B70
    }
}

/// Треугольник «я» носом вправо (по ходу полосы).
private struct MeTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.1))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.3, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.maxY - rect.height * 0.1))
        path.closeSubpath()
        return path
    }
}
