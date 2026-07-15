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
        NavigationStack {
            Group {
                if sortedCameras.isEmpty {
                    ContentUnavailableView(
                        "Камеры не найдены",
                        systemImage: "location.slash",
                        description: Text("Двигайтесь — приложение подберёт ближайшие камеры вокруг вас.")
                    )
                } else {
                    List(sortedCameras) { camera in
                        Button { onSelect(camera); dismiss() } label: { row(camera) }
                            .listRowBackground(Theme.surface)
                            .listRowSeparatorTint(Theme.stroke)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.background)
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

    private var sortedCameras: [Camera] {
        guard let coordinate = env.location.currentCoordinate else { return env.location.nearbyCameras }
        return env.location.nearbyCameras.sorted { $0.distance(from: coordinate) < $1.distance(from: coordinate) }
    }

    private func row(_ camera: Camera) -> some View {
        HStack(spacing: 14) {
            Image(systemName: camera.kind.symbolName)
                .font(.rounded(15, .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(camera.kind.tint.gradient, in: Circle())

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
