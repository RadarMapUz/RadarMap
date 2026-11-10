//
//  MapAttribution.swift
//  RadarMap
//
//  Подпись данных карты: маленькая «i» в углу и «© OpenMapTiles
//  © OpenStreetMap» рядом — пять секунд при показе, затем тает.
//
//  Раньше на телефоне внизу висела кнопка «ⓘ» MapLibre — у края нижней
//  панели, наполовину под ней («убери, висит», владелец, 12.10), а в машине
//  подпись стояла всё время. Правила OSMF (Attribution Guidelines) прямо
//  разрешают иначе: подпись в углу карты при показе, затем свернуть «после
//  пяти секунд» или при касании карты, — если лицензию можно найти, когда
//  ищешь. Лицензия OpenMapTiles (схема тайлов, CC BY 4.0) просит того же:
//  «© OpenMapTiles © OpenStreetMap contributors» в углу карты, со ссылками.
//  Поэтому подпись тает, а «i» остаётся (28.F): её касание — лист со
//  ссылками и переходом к лицензиям. Своя кнопка, а не системная MapLibre:
//  та стоит по краю вида карты, а у нас край карты — под нижней панелью.
//  Название и логотип MapLibre на карте лицензия движка (BSD) не требует —
//  её текст лежит в «Лицензиях».
//

import SwiftUI

struct MapAttribution: View {
    /// В машине касаний нет (окно CarPlay без жестов): там только подпись.
    var interactive = true
    @State private var shown = true
    /// DEBUG `-mapAttribution`: лист открыт сразу — на снимок без касаний.
    @State private var showSheet = MapAttribution.debugArgument("-mapAttribution")

    var body: some View {
        HStack(spacing: 4) {
            if interactive {
                Button {
                    showSheet = true
                } label: {
                    Image(systemName: "info")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 20, height: 20)
                        .background(Theme.surface.opacity(0.85), in: Circle())
                        .overlay(Circle().strokeBorder(Theme.textTertiary.opacity(0.35), lineWidth: 0.5))
                }
                // Мишень — 44 pt по правилу 22, а вид остаётся мелким: «i»
                // нужна раз в жизни и не должна спорить с кнопками карты.
                .tapTarget()
                .accessibilityLabel(Text("Данные карты и лицензии"))
            }
            Text(verbatim: "© OpenMapTiles © OpenStreetMap")
                .font(.dense(10, .medium))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.background.opacity(0.6), in: Capsule())
                .opacity(shown ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(!shown)
        }
        .task {
            // DEBUG `-holdAttribution`: подпись не тает — снимок не ловит
            // пять секунд холодного запуска.
            if Self.debugArgument("-holdAttribution") { return }
            await Task.pause(seconds: AppConfig.mapAttributionSeconds)
            withMotion(.easeOut(duration: 0.6)) { shown = false }
        }
        .sheet(isPresented: Binding(get: { interactive && showSheet },
                                    set: { showSheet = $0 })) {
            MapAttributionSheet()
        }
    }
}

extension MapAttribution {
    fileprivate static func debugArgument(_ name: String) -> Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains(name)
        #else
        false
        #endif
    }
}

/// Лист «i»: чьи данные на карте, со ссылками, и путь к лицензиям.
struct MapAttributionSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(DataSource.map, id: \.self) { DataSourceRow(source: $0) }
                } footer: {
                    Text("Карта собрана из данных OpenStreetMap по схеме OpenMapTiles.")
                }
                Section {
                    NavigationLink {
                        DataSourcesPage()
                    } label: {
                        SettingsRow(.openData)
                    }
                    NavigationLink {
                        LicensesPage()
                    } label: {
                        SettingsRow(.licenses)
                    }
                }
            }
            .settingsPage("Данные карты")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
