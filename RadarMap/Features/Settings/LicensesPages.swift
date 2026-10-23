//
//  LicensesPages.swift
//  RadarMap
//
//  «Источники данных» и «Лицензии» (28.F). Данные — по строке на источник
//  со ссылкой, как требуют их лицензии; код и шрифты — полный текст
//  лицензии на английском оригинале. Список и тексты — Models/Attribution.
//  Те же страницы открываются из настроек («О приложении») и из листа «i»
//  на карте.
//

import SwiftUI
import os

// MARK: - Источники данных

struct DataSourcesPage: View {
    var body: some View {
        List {
            Section {
                ForEach(DataSource.map, id: \.self) { DataSourceRow(source: $0) }
            } header: {
                Text("Карта")
            } footer: {
                Text("Карта собрана из данных OpenStreetMap по схеме OpenMapTiles.")
            }
            Section {
                DataSourceRow(source: .openData)
                DataSourceRow(source: .openMeteo)
                DataSourceRow(source: .osmBright)
            } header: {
                Text("Данные и стиль")
            }
            Section {
                NavigationLink {
                    LicensesPage()
                } label: {
                    SettingsRow(.licenses)
                }
            } footer: {
                Text("Приложение бесплатное, без рекламы и без слежки.")
            }
        }
        .settingsPage("Источники данных")
    }
}

/// Строка источника: название, что от него взято, лицензия; касание —
/// страница, на которую лицензия велит сослаться.
struct DataSourceRow: View {
    let source: DataSource

    var body: some View {
        Link(destination: source.url) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    title
                        .foregroundStyle(Theme.textPrimary)
                    detail
                        .font(.rounded(13))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: source.licenseName)
                        .font(.rounded(12, .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.rounded(12, .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .tint(Theme.textPrimary)
    }

    /// Подписи, которые лицензиар задал сам («© OpenMapTiles», «Weather data
    /// by Open-Meteo.com»), — дословно; остальное переводится.
    @ViewBuilder private var title: some View {
        switch source {
        case .openMapTiles: Text(verbatim: "© OpenMapTiles")
        case .openStreetMap: Text("© участники OpenStreetMap")
        case .openData: Text("Портал открытых данных Республики Узбекистан")
        case .openMeteo: Text(verbatim: "Weather data by Open-Meteo.com")
        case .osmBright: Text(verbatim: "OSM Bright © MapTiler, OpenMapTiles, Mapbox")
        }
    }

    @ViewBuilder private var detail: some View {
        switch source {
        case .openMapTiles: Text("Схема векторной карты")
        case .openStreetMap: Text("Дороги, адреса, заведения, ограничения скорости, маршруты")
        case .openData: Text("Камеры, банкоматы и гостиницы (data.egov.uz)")
        case .openMeteo: Text("Погода на перевалах")
        case .osmBright: Text("Основа стиля карты")
        }
    }
}

// MARK: - Лицензии

struct LicensesPage: View {
    var body: some View {
        List {
            Section {
                ForEach(ThirdPartyLicense.allCases) { license in
                    NavigationLink {
                        LicenseTextPage(license: license)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: license.name)
                                .foregroundStyle(Theme.textPrimary)
                            Text(verbatim: license.licenseName)
                                .font(.rounded(13))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text("Программы и шрифты")
            } footer: {
                Text("Полный текст лицензии — на языке оригинала.")
            }
            Section {
                licenseLink("Open Database License 1.0", AppConfig.odblURL)
                licenseLink("Creative Commons Attribution 4.0", AppConfig.ccBy4URL)
                licenseLink("Creative Commons Attribution-ShareAlike 4.0", AppConfig.ccBySa4URL)
            } header: {
                Text("Лицензии данных")
            } footer: {
                Text("На этих условиях распространяются данные OpenStreetMap, схема OpenMapTiles, погода и наборы портала открытых данных.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsPage("Лицензии")
    }

    private func licenseLink(_ name: String, _ url: URL) -> some View {
        Link(destination: url) {
            HStack {
                Text(verbatim: name)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.rounded(12, .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .tint(Theme.textPrimary)
    }
}

/// Полный текст лицензии компонента, дословно.
struct LicenseTextPage: View {
    let license: ThirdPartyLicense
    @State private var blocks: [String] = []
    @State private var failed = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Link(destination: license.url) {
                    Label {
                        Text(verbatim: license.url.host() ?? license.url.absoluteString)
                    } icon: {
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.rounded(14, .medium))
                    .foregroundStyle(Theme.accent)
                }
                .padding(.bottom, 4)
                if failed {
                    Text("Текст лицензии не найден в сборке.")
                        .foregroundStyle(Theme.textSecondary)
                }
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    Text(verbatim: block)
                        .font(.footnote)
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .settingsPage(nil)
        .navigationTitle(Text(verbatim: license.name))
        .task {
            let license = license
            do {
                blocks = try await offMain { LicenseText.blocks(try LicenseText.load(license)).map(LicenseText.reflow) }
            } catch {
                Log.app.error("лицензия \(license.rawValue, privacy: .public) не прочитана: \(error.localizedDescription, privacy: .public)")
                failed = true
            }
        }
    }
}
