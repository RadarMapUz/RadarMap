//
//  LongTripMapSection.swift
//  RadarMap
//
//  «Перед дальней дорогой» (12.4): карта без интернета по пути — области
//  коридора по ходу, каждая со своим состоянием, и одна кнопка, которая
//  докачивает всё недостающее (области, граф маршрута без сети, файлы
//  заведений) тем же путём, что карточка «Карта по пути без интернета»
//  (RouteCorridorService.download).
//
//  По мобильной сети кнопка есть, но с размером и словами об этом: здесь
//  человек сам открыл лист и сам решает про мегабайты — в отличие от
//  карточки, которая по сотовой не всплывает вовсе.
//

import SwiftUI

struct LongTripMapSection: View {
    @Environment(AppEnvironment.self) private var env
    /// Файлы заведений впереди, которых нет на телефоне (байты).
    let missingBytes: Int

    var body: some View {
        let regions = env.corridor.regionPlan(route: env.route)
        let offer = env.corridor.offer()
        Section {
            if let regions {
                ForEach(regions.rows) { regionRow($0) }
            } else {
                Text(env.offlineMaps.catalog == nil
                     ? String(localized: "Список областей не загрузился — проверьте интернет.")
                     : String(localized: "Считаем области по пути…"))
                    .font(.rounded(14))
                    .foregroundStyle(Theme.textSecondary)
                    .listRowBackground(Theme.surface)
            }
            if let bytes = offer?.graphBytes {
                row(title: String(localized: "Маршрут без сети"), caption: OfflineMapsView.size(Int64(bytes))) {
                    Image(systemName: "arrow.down.circle")
                        .font(.rounded(20))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            let total = (offer?.totalBytes ?? 0) + Int64(missingBytes)
            if total > 0 {
                downloadButton(total: total, offer: offer)
                    .id(LongTripSheet.Anchor.download)
            }
        } header: {
            Text("Карта без интернета")
                .font(.rounded(13, .semibold))
                .foregroundStyle(Theme.textSecondary)
                .textCase(nil)
        } footer: {
            Text(verbatim: footer(regions: regions, pending: (offer?.totalBytes ?? 0) + Int64(missingBytes) > 0))
                .font(.rounded(12))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func footer(regions: LongTripBrief.Regions?, pending: Bool) -> String {
        if pending, !env.network.isOnline {
            return String(localized: "Нет связи — скачать сейчас не выйдет. Камеры предупреждают и без сети.")
        }
        if pending, env.network.isExpensive {
            return String(localized: "Сейчас мобильная сеть — проверьте тариф или дождитесь Wi-Fi.")
        }
        if let regions, regions.allOnPhone, !pending {
            return String(localized: "Карта всего пути на телефоне — без связи дорога не будет серой.")
        }
        return String(localized: "Камеры предупреждают и без сети — карта нужна, чтобы дорога не была серой.")
    }

    // MARK: - Строки

    private func regionRow(_ row: LongTripBrief.RegionRow) -> some View {
        let title = row.region.title(language: OfflineMapsView.language(env.settings.appLanguage))
        let size = OfflineMapsView.size(row.region.totalBytes)
        return self.row(title: title, caption: caption(row.status, size: size)) {
            switch row.status {
            case .ready, .updateAvailable:
                Image(systemName: "checkmark.circle.fill")
                    .font(.rounded(20))
                    .foregroundStyle(Theme.success)
            case .downloading(let share):
                ProgressView(value: share)
                    .frame(width: 56)
            case .missing:
                Image(systemName: "arrow.down.circle")
                    .font(.rounded(20))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func caption(_ status: LongTripBrief.RegionStatus, size: String) -> String {
        switch status {
        case .ready:              return String(localized: "На телефоне")
        case .updateAvailable:    return String(localized: "На телефоне") + " · " + String(localized: "Есть обновление")
        case .downloading(let p): return String(localized: "Скачивается") + " · \(Int(p * 100)) %"
        case .missing:            return size
        }
    }

    private func row<Trailing: View>(title: String, caption: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(verbatim: caption)
                    .font(.rounded(12))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            trailing()
                .accessibilityHidden(true)
        }
        .frame(minHeight: Theme.controlSize)
        .listRowBackground(Theme.surface)
        .listRowSeparatorTint(Theme.stroke)
        .accessibilityElement(children: .combine)
    }

    private func downloadButton(total: Int64, offer: RouteCorridor.Offer?) -> some View {
        Button {
            guard let points = env.route.selected?.points,
                  let destination = env.route.destinationCoordinate else { return }
            let key = RouteCorridor.routeKey(destination: destination)
            withMotion(Motion.standard) {
                env.corridor.download(offer ?? RouteCorridor.Offer(regions: [], graphBytes: nil),
                                      key: key, points: points)
            }
        } label: {
            // Синяя, как у карточки «Карта по пути»: то же действие.
            Text(String(format: String(localized: "Скачать недостающее · %@"),
                        Formatting.unbreakable(OfflineMapsView.size(total))))
                .font(.rounded(16, .bold))
                .foregroundStyle(Theme.onAccentFill)
                .frame(maxWidth: .infinity)
                .frame(minHeight: Theme.controlSize)
                .background(Theme.accentFill, in: RoundedRectangle(cornerRadius: Theme.cornerMedium,
                                                                  style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .disabled(!env.network.isOnline)
        .listRowBackground(Theme.surface)
        .accessibilityLabel(Text(String(format: String(localized: "Скачать недостающее, %@"),
                                        CorridorOfferText.spokenSize(total))))
    }
}
