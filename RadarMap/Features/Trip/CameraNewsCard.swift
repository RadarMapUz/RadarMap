//
//  CameraNewsCard.swift
//  RadarMap
//
//  «Новые камеры на ваших дорогах» (31E, п. 4): после обновления базы — те
//  новые камеры, что стоят там, где водитель ездил последние два месяца
//  (RoadMemoryService / CameraNews). Это новость, а не статистика, поэтому
//  карточка — над периодом и убирается одним «Понятно».
//

import SwiftUI

struct CameraNewsCard: View {
    @Environment(AppEnvironment.self) private var env
    let items: [CameraNews.Item]

    /// Камеры новостей — по id из базы; ищем на смену списка, не в body.
    @State private var cameras: [Camera] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconBadge(symbol: Icon.cameras, tint: Theme.Icon.camera, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Новые камеры на ваших дорогах: \(items.count)"))
                        .font(.rounded(14, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Появились с обновлением базы там, где вы ездили за два месяца")
                        .font(.rounded(13))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if !cameras.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(cameras.prefix(AppConfig.cameraNewsRows).enumerated()), id: \.element.id) { index, camera in
                        if index > 0 { Divider().overlay(Theme.stroke) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(camera.displayTitle)
                                .font(.rounded(15, .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(camera.kind.displayName)
                                .font(.rounded(13))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            SecondaryButton(title: "Понятно") {
                withMotion(Motion.standard) { env.roadMemory.dismissNews() }
            }
        }
        .statCard()
        .task(id: items.map(\.id)) {
            let ids = Set(items.map(\.id))
            let order = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
            cameras = env.cameras.cameras.filter { ids.contains($0.id) }
                .sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        }
    }
}
