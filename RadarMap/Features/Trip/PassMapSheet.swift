//
//  PassMapSheet.swift
//  RadarMap
//
//  Где именно стояла камера: карта «подлетает» к точке проезда, маркер
//  пульсирует цветом честности, внизу — скорость против лимита и цена вопроса.
//  Открывается тапом по строке «Пройденные камеры».
//

import SwiftUI
import MapKit

struct PassMapSheet: View {
    let pass: PassedCamera
    /// Трек поездки вокруг камеры — виден контекст: откуда ехал и куда.
    var track: [TrackPoint] = []

    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition
    @State private var appeared = false

    init(pass: PassedCamera, track: [TrackPoint] = []) {
        self.pass = pass
        self.track = track
        let center = pass.coordinate ?? CLLocationCoordinate2D(latitude: 41.3111, longitude: 69.2797)
        // Старт издалека и сверху — при появлении камера красиво подлетает.
        _position = State(initialValue: .camera(
            MapCamera(centerCoordinate: center, distance: 14_000)))
    }

    private var honestyColor: Color {
        PassStyle.color(speed: pass.speedKmh, limit: pass.limitKmh)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                map.ignoresSafeArea()
                infoCard
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 28)
            }
            .background(Theme.background)
            .navigationTitle("Проезд камеры")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
            .onAppear {
                guard let coordinate = pass.coordinate else { return }
                // Подлёт: с высоты — к камере, с лёгким наклоном для объёма.
                withAnimation(.spring(duration: 1.6, bounce: 0.12).delay(0.25)) {
                    position = .camera(MapCamera(centerCoordinate: coordinate,
                                                 distance: 1300, pitch: 48))
                }
                withAnimation(.spring(duration: 0.6, bounce: 0.2).delay(0.5)) {
                    appeared = true
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Карта

    private var map: some View {
        Map(position: $position) {
            if track.count >= 2 {
                MapPolyline(coordinates: track.map {
                    CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                })
                .stroke(LinearGradient(colors: [Theme.accent, Theme.intelligent],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            if let coordinate = pass.coordinate {
                Annotation("", coordinate: coordinate, anchor: .center) {
                    PassPulseMarker(color: honestyColor, icon: pass.kind.symbolName)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll,
                            showsTraffic: false))
    }

    // MARK: Карточка проезда

    private var infoCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: pass.kind.symbolName)
                    .font(.rounded(15, .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(pass.kind.tint.gradient, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(pass.location.isEmpty ? pass.kind.displayName : pass.location)
                        .font(.rounded(16, .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    Text("\(pass.kind.displayName) · \(pass.date.formatted(date: .omitted, time: .shortened))")
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
            }

            Rectangle().fill(Theme.stroke).frame(height: 1)

            HStack(spacing: 14) {
                if let limit = pass.limitKmh {
                    SpeedLimitSign(limit: limit, diameter: 44)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("ваша скорость")
                        .font(.rounded(11))
                        .foregroundStyle(Theme.textTertiary)
                    Text("\(Int(pass.speedKmh)) км/ч")
                        .font(.rounded(22, .heavy).monospacedDigit())
                        .foregroundStyle(honestyColor)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 8)
                statusChip
            }
        }
        .padding(16)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
            .stroke(Theme.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }

    @ViewBuilder private var statusChip: some View {
        let fine = pass.limitKmh.map {
            FineSchedule.fine(overKmh: pass.speedKmh - Double($0))
        } ?? 0
        if fine > 0 {
            VStack(alignment: .trailing, spacing: 2) {
                Label("превышение", systemImage: "exclamationmark.triangle.fill")
                    .font(.rounded(12, .bold))
                    .foregroundStyle(Theme.danger)
                Text("риск ≈ \(Formatting.money(fine))")
                    .font(.rounded(11, .semibold))
                    .foregroundStyle(Theme.danger)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            Label("в лимите", systemImage: "checkmark.shield.fill")
                .font(.rounded(12, .bold))
                .foregroundStyle(Theme.success)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Theme.success.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

// MARK: - Пульсирующий маркер проезда

/// Маленький слой с одним повторяющимся кольцом — GPU-нагрузка ничтожна,
/// живёт только пока открыт этот экран.
private struct PassPulseMarker: View {
    let color: Color
    let icon: String
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(pulse ? 0 : 0.55), lineWidth: 2.5)
                .frame(width: 36, height: 36)
                .scaleEffect(pulse ? 2.7 : 1)
            Circle()
                .fill(color.gradient)
                .frame(width: 38, height: 38)
                .shadow(color: color.opacity(0.65), radius: 9)
            Image(systemName: icon)
                .font(.rounded(15, .bold))
                .foregroundStyle(.white)
        }
        .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2).frame(width: 38, height: 38))
        .onAppear {
            withAnimation(.easeOut(duration: 1.7).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}
