//
//  OfflineMapsView.swift
//  RadarMap
//
//  «Офлайн-карты»: скачать область, чтобы карта рисовалась без связи.
//
//  Первой — область дома (или та, где человек сейчас): её и скачивают в
//  девяти случаях из десяти. Остальные — списком, с размером: трасса
//  Ташкент — Самарканд — это две-три области, и решение «качать ли по
//  мобильной сети» человек принимает по числу мегабайт.
//
//  Камеры и оповещения от этого экрана не зависят никак — база камер и так
//  целиком на телефоне. Здесь только картинка карты.
//

import CoreLocation
import SwiftUI

struct OfflineMapsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let service = env.offlineMaps
        List {
            Section {
                Text("Карта области сохраняется на телефоне и рисуется без интернета — на трассе, в тоннеле, в роуминге. Камеры предупреждают и без этого: их база всегда на телефоне.")
                    .font(.rounded(15))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let catalog = service.catalog {
                if let mine = recommended(in: catalog) {
                    Section {
                        row(mine)
                    } header: {
                        Text("Ваша область")
                    }
                }
                Section {
                    ForEach(sorted(catalog.regions)) { row($0) }
                } header: {
                    Text("Все области")
                } footer: {
                    Text("Занято на телефоне: \(Self.size(service.usedBytes)). Вся страна — \(Self.size(catalog.totalBytes)). Лучше качать по Wi-Fi.")
                }
            } else if service.isLoadingCatalog {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Загружаем список областей…")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            } else {
                Section {
                    Button("Повторить") {
                        Task { await service.refreshCatalog() }
                    }
                } footer: {
                    Text("Список областей не загрузился — проверьте интернет.")
                }
            }
        }
        .navigationTitle("Офлайн-карты")
        .task { await service.refreshCatalog() }
    }

    // MARK: - Строка области

    private func row(_ region: RegionCatalog.Region) -> some View {
        let service = env.offlineMaps
        let state = service.state(for: region)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(region.title(language: Self.language(env.settings.appLanguage)))
                    .font(.rounded(17, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(caption(region, state: state))
                    .font(.rounded(13))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            control(region, state: state)
        }
        .padding(.vertical, 4)
        .swipeActions {
            if state == .ready || state == .updateAvailable {
                Button(role: .destructive) {
                    service.delete(region)
                } label: {
                    Label("Удалить", systemImage: "trash")
                }
            }
        }
    }

    private func caption(_ region: RegionCatalog.Region, state: OfflineMapService.State) -> String {
        // Слово переводится, число пристраивается: без процента внутри ключа
        // перевода, где его легко сломать экранированием.
        let size = Self.size(region.totalBytes)
        switch state {
        case .ready:              return String(localized: "Скачано") + " · " + size
        case .updateAvailable:    return String(localized: "Есть обновление") + " · " + size
        case .downloading(let p): return String(localized: "Скачивается") + " · \(Int(p * 100)) %"
        case .failed(let message): return message
        case .notDownloaded:      return size
        }
    }

    @ViewBuilder
    private func control(_ region: RegionCatalog.Region, state: OfflineMapService.State) -> some View {
        let service = env.offlineMaps
        switch state {
        case .notDownloaded, .failed:
            Button {
                service.download(region)
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.rounded(26))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .tapTarget()
            .accessibilityLabel(Text("Скачать"))
        case .downloading(let fraction):
            HStack(spacing: 10) {
                ProgressView(value: fraction)
                    .frame(width: 70)
                Button {
                    service.cancel(region)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.rounded(22))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .tapTarget()
                .accessibilityLabel(Text("Отменить"))
            }
        case .updateAvailable:
            Button("Обновить") { service.download(region) }
                .font(.rounded(15, .semibold))
                .buttonStyle(.bordered)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(.rounded(24))
                .foregroundStyle(Theme.success)
                .accessibilityLabel(Text("Скачано"))
        }
    }

    // MARK: - Помощники

    /// Область дома — по адресу «Дом», иначе по выученному дому, иначе там,
    /// где человек сейчас.
    private func recommended(in catalog: RegionCatalog) -> RegionCatalog.Region? {
        let anchor = OfflineOffer.anchor(
            home: env.settings.homePlace?.coordinate,
            learnedHome: env.learnedPlaces.first { $0.kind == .home }?.coordinate,
            current: env.location.currentCoordinate)
        return anchor.flatMap { catalog.region(containing: $0) }
    }

    private func sorted(_ regions: [RegionCatalog.Region]) -> [RegionCatalog.Region] {
        let language = Self.language(env.settings.appLanguage)
        return regions.sorted { $0.title(language: language) < $1.title(language: language) }
    }

    static func language(_ setting: AppLanguage) -> String { setting.mapCode }

    /// «20,2 МБ» / «20,2 MB» — по языку приложения, как остальные числа.
    /// ByteCountFormatter брал локаль телефона: на узбекском интерфейсе при
    /// русской системе карточка писала «Toshkent · 20,2 МБ» кириллицей
    /// (снимок 14.9 — до того подпись обрезалась и этого не было видно).
    static func size(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(Formatting.numberLocale))
    }
}
