//
//  RouteProgressRail.swift
//  RadarMap
//
//  Полоса хода маршрута у правого края (29.B, как у Amap): низ — старт,
//  верх — финиш, отметка «я», отрезки цветом пробок, значки камер маршрута.
//  Только в поездке с маршрутом; ставится под колонкой кнопок и над нижней
//  панелью (MapFrameState.rail), не заходя ни на то, ни на другое.
//
//  Раскладку считает RouteProgressBar вне главного потока — раз на маршрут и
//  на новые пробки. Прогресс маршрута меняется на каждом фиксе, поэтому его
//  читает только эта маленькая вью (ARCHITECTURE, правило 13), а сама
//  полоса перерисовывается, лишь когда отметка «я» сдвинулась на шаг.
//

import CoreLocation
import MapKit
import SwiftUI

/// Раскладка полосы для текущего маршрута — состояние экрана, не вью.
@MainActor
@Observable
final class RouteRailState {
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

/// Читает прогресс маршрута (тик) и решает, видна ли полоса.
struct RouteProgressRailGate: View {
    @Environment(AppEnvironment.self) private var env
    let frame: MapFrameState
    @State private var state = RouteRailState()

    /// Ключ пересчёта раскладки: маршрут (объект полилайна), пробки, камеры.
    private struct Key: Equatable {
        var route: ObjectIdentifier?
        var traffic: Int
        var cameras: Int
    }

    var body: some View {
        let shown = env.location.isTripActive && env.route.isActive
        let key = Key(route: shown ? env.route.polyline.map(ObjectIdentifier.init) : nil,
                      traffic: env.traffic.revision * 2 + (env.traffic.isShown ? 1 : 0),
                      cameras: env.route.camerasOnRoute.count)
        // ZStack с пустой подложкой, а не Group: у пустой Group нет вью, и
        // `.task` на ней не запускается — раскладка не считалась никогда.
        ZStack {
            Color.clear.allowsHitTesting(false)
            if shown, let rail = frame.rail, state.layout.length > 0 {
                let height = rail.upperBound - rail.lowerBound
                let progress = RouteProgressBar.fraction(progress: env.route.progressAlong,
                                                         length: state.layout.length)
                GeometryReader { geo in
                    RouteProgressRail(layout: state.layout,
                                      progress: RouteProgressBar.step(progress, height: height,
                                                                      points: AppConfig.routeRailStepPoints),
                                      height: height)
                        .equatable()
                        .position(x: geo.size.width - AppConfig.routeRailEdgeInset - AppConfig.routeRailMeSize / 2,
                                  y: (rail.lowerBound + rail.upperBound) / 2)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
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
struct RouteProgressRail: View, Equatable {
    let layout: RouteProgressBar.Layout
    /// Доля пройденного, уже округлённая до шага.
    let progress: Double
    let height: Double

    private var track: CGFloat { AppConfig.routeRailTrackWidth }

    var body: some View {
        let h = CGFloat(height)
        ZStack(alignment: .bottom) {
            // Подложка — кайма цвета панелей: полоса читается и на светлой
            // земле, и на тёмном асфальте поездки.
            Capsule()
                .fill(Theme.surface)
                .frame(width: track + 3, height: h + 3)
                .offset(y: 1.5)
            ForEach(Array(layout.segments.enumerated()), id: \.offset) { _, segment in
                Rectangle()
                    .fill(Self.colour(segment.tone))
                    .frame(width: track, height: max(0, CGFloat(segment.to - segment.from) * h))
                    .offset(y: -CGFloat(segment.from) * h)
            }
            // Пройденное — приглушено поверх: уже не решение, а память.
            Rectangle()
                .fill(Theme.surface.opacity(0.62))
                .frame(width: track, height: CGFloat(progress) * h)
            ForEach(RouteProgressBar.thinned(layout.cameras, minGap: Double(AppConfig.routeRailCameraSize) / max(1, height)),
                    id: \.id) { mark in
                Circle()
                    .fill(Color(uiColor: Theme.rgb(Self.cameraHex(mark.kind))))
                    .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                    .frame(width: AppConfig.routeRailCameraSize, height: AppConfig.routeRailCameraSize)
                    .opacity(mark.fraction < progress ? 0.45 : 1)
                    .offset(y: -CGFloat(mark.fraction) * h + AppConfig.routeRailCameraSize / 2)
            }
            Circle()
                .fill(Theme.accentFill)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                .overlay(Image(systemName: "location.north.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white))
                .frame(width: AppConfig.routeRailMeSize, height: AppConfig.routeRailMeSize)
                .offset(y: -CGFloat(progress) * h + AppConfig.routeRailMeSize / 2)
        }
        .frame(width: AppConfig.routeRailMeSize, height: h, alignment: .bottom)
        .accessibilityElement()
        .accessibilityLabel(Text("Ход маршрута"))
        .accessibilityValue(Text(String(format: String(localized: "Пройдено %lld %%"), Int((progress * 100).rounded()))))
    }

    /// Цвета пробок — те же, что слой пробок и линия маршрута (RouteColors);
    /// «нет данных» — нейтральный серый, не зелёный.
    private static func colour(_ tone: RouteProgressBar.Tone) -> Color {
        switch tone {
        case .unknown: return Theme.adaptive(0x9AA3B0, 0x5D6470)
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
