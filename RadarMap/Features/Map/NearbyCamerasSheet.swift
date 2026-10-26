//
//  NearbyCamerasSheet.swift
//  RadarMap
//
//  Нижний лист со списком ближайших камер (тап → центрирование на карте).
//

import SwiftUI

struct NearbyCamerasSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let onSelect: (Camera) -> Void

    var body: some View {
        // Один раз за тело: список читался дважды, и каждый раз — полная
        // сортировка с геодезикой на каждое сравнение (аудит 11.10).
        let cameras = sortedCameras
        NavigationStack {
            Group {
                if cameras.isEmpty {
                    ContentUnavailableView(
                        "Камеры не найдены",
                        systemImage: Icon.noCameras,
                        description: Text("Двигайтесь — приложение подберёт ближайшие камеры вокруг вас.")
                    )
                } else {
                    List(cameras) { camera in
                        Button { onSelect(camera); dismiss() } label: { row(camera) }
                            .listRowBackground(Theme.surface)
                            .listRowSeparatorTint(Theme.stroke)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.background)
            .onAppear { env.usage.noteScreen("nearby") }
            .navigationTitle("Ближайшие камеры")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// Расстояние считается один раз на камеру, плоским приближением: для
    /// порядка двадцати точек вокруг этого достаточно.
    private var sortedCameras: [Camera] {
        guard let c = env.location.currentCoordinate else { return env.location.nearbyCameras }
        return env.location.nearbyCameras
            .map { ($0, GeoMath.fastDistance(c.latitude, c.longitude, $0.lat, $0.lon)) }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    private func row(_ camera: Camera) -> some View {
        HStack(spacing: 14) {
            CameraIcon(kind: camera.kind, side: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(camera.displayTitle)
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(camera.subtitle)
                    .font(.rounded(12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let coordinate = env.location.currentCoordinate {
                Text(Formatting.distance(camera.distance(from: coordinate)))
                    .font(.rounded(13, .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.vertical, 4)
    }
}
