//
//  SettingsView.swift
//  RadarMap
//
//  Настройки — как «Настройки» iPhone: первый экран — короткий список
//  разделов с цветными иконками, каждый раздел — своя страница.
//
//  Раньше это был один экран на четырнадцать секций и три экрана высотой:
//  нужный тумблер искали прокруткой, а «Офлайн-карты» терялись в середине
//  «Карты». Список разделов читается за взгляд, справа у раздела — текущее
//  значение главного выбора (профиль, тема, язык), чтобы не заходить внутрь
//  ради проверки. Сами настройки и их поведение не менялись — только место.
//  Страницы — SettingsPages.swift.
//

import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var showFeedback = false
    /// DEBUG `-settingsPage <alerts|speed|trip|route|map|places|learning|battery|privacy|database|backup|language|help>`:
    /// открыть страницу раздела сразу — на снимок без касаний.
    @State private var path = NavigationPath()

    /// Версия и номер сборки: первое, что спрашивают в ответ на письмо.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    var body: some View {
        let settings = env.settings
        NavigationStack(path: $path) {
            List {
                Section {
                    link(.alerts, value: settings.alertProfile.title) { AlertSettingsPage() }
                    link(.speed, value: settings.speedLimitsEnabled
                         ? Self.tolerance(settings.overspeedTolerance) : String(localized: "Выкл.")) {
                        SpeedSettingsPage()
                    }
                    link(.trip, value: settings.tripStartMode.title) { TripSettingsPage() }
                    link(.route) { RouteSettingsPage() }
                }

                Section {
                    link(.map, value: settings.mapAppearance.title) { MapSettingsPage() }
                    link(.offline, value: offlineValue) { OfflineMapsView().settingsPage() }
                    link(.places) { PlacesSettingsPage() }
                }

                Section {
                    link(.learning) { LearningSettingsPage() }
                    link(.battery, value: settings.adaptiveGPS
                         ? String(localized: "Адаптивный GPS") : nil) { BatterySettingsPage() }
                }

                Section {
                    link(.help) { HelpSettingsPage() }
                    Button {
                        showFeedback = true
                    } label: {
                        SettingsRow(.feedback)
                    }
                    .tint(Theme.textPrimary)
                    // Второй этаж (7.4): то, что меняют раз в год или не
                    // меняют никогда, — база, данные, язык, приватность,
                    // источники и версия. В корне было 19 строк, и нужная
                    // терялась среди справочных.
                    link(.about, value: Self.appVersionShort) { aboutPage }
                }
            }
            .settingsPage("Настройки")
            .navigationDestination(for: String.self) { Self.debugPage($0) }
            .onAppear {
                env.usage.noteScreen("settings")
                #if DEBUG
                let args = ProcessInfo.processInfo.arguments
                if let i = args.firstIndex(of: "-settingsPage"), i + 1 < args.count, path.isEmpty {
                    path.append(args[i + 1])
                }
                #endif
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .sheet(isPresented: $showFeedback) {
                FeedbackFormView()
            }
        }
    }

    /// «О приложении» — второй этаж настроек.
    private var aboutPage: some View {
        let settings = env.settings
        return List {
            Section {
                link(.database, value: "v\(env.cameras.dbVersion)") { DatabaseSettingsPage() }
                // Резервная копия поездок. Ссылка пропала 28.08 при
                // переделке настроек («экран за рулём»), и полтора месяца
                // сохранить историю перед сменой телефона было нечем:
                // она живёт только здесь.
                link(.backup) { BackupSettingsPage() }
                link(.language, value: settings.appLanguage.title) { LanguageSettingsPage() }
                link(.privacy) { PrivacySettingsPage() }
            }
            Section {
                // Страница проекта: что это, откуда данные, политика,
                // возможность помочь. Внутрь приложения платёжная кнопка
                // не ставится намеренно — App Review отдельно смотрит на
                // ссылки, уводящие на стороннюю оплату (Guideline 3.1.1).
                // Здесь — обычная ссылка на сайт проекта.
                Link(destination: AppConfig.projectPageURL) {
                    SettingsRow(.project, accessory: "arrow.up.right")
                }
                .tint(Theme.textPrimary)
                // Условие лицензии CC BY-SA 4.0 портала: ссылка на источник.
                Link(destination: AppConfig.openDataURL) {
                    SettingsRow(.openData, accessory: "arrow.up.right")
                }
                .tint(Theme.textPrimary)
                SettingsRow(.version, value: Self.appVersion)
            } footer: {
                Text("Карты и ограничения скорости — © участники OpenStreetMap. Камеры, банкоматы и гостиницы — Портал открытых данных Республики Узбекистан (CC BY-SA 4.0). Погода на перевалах — Weather data by Open-Meteo.com (CC BY 4.0). Приложение бесплатное, без рекламы и без слежки.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsPage("О приложении")
    }

    /// Версия без номера сборки — справа у «О приложении».
    static var appVersionShort: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    @ViewBuilder private static func debugPage(_ name: String) -> some View {
        switch name {
        case "alerts": AlertSettingsPage()
        case "speed": SpeedSettingsPage()
        case "trip": TripSettingsPage()
        case "route": RouteSettingsPage()
        case "map": MapSettingsPage()
        case "places": PlacesSettingsPage()
        case "learning": LearningSettingsPage()
        case "battery": BatterySettingsPage()
        case "privacy": PrivacySettingsPage()
        case "database": DatabaseSettingsPage()
        case "backup": BackupSettingsPage()
        case "language": LanguageSettingsPage()
        case "fuel": FuelSettingsPage()
        case "family": FamilyShareSettingsPage()
        case "fines": Form { FineCheckSection() }.settingsPage("Штрафы")
        default: HelpSettingsPage()
        }
    }

    private func link<Page: View>(_ item: SettingsItem, value: String? = nil,
                                  @ViewBuilder page: @escaping () -> Page) -> some View {
        NavigationLink {
            page()
        } label: {
            SettingsRow(item, value: value)
        }
    }

    /// Справа у «Офлайн-карт»: сколько занято, если что-то скачано.
    private var offlineValue: String? {
        let used = env.offlineMaps.usedBytes
        return used > 0 ? OfflineMapsView.size(used) : nil
    }

    static func tolerance(_ value: Double) -> String {
        value == 0
            ? String(localized: "0 км/ч")
            : String(format: String(localized: "+%lld км/ч"), Int(value))
    }
}

// MARK: - Строка раздела

/// Раздел настроек: иконка, цвет плитки, название. Один список вместо
/// разбросанных по строкам `Label(systemImage:)` — цвета разделов не
/// повторяются у соседей и не спорят с цветами камер.
enum SettingsItem {
    case alerts, speed, trip, route
    case map, offline, places
    case learning, battery, privacy
    case database, backup, language
    case help, feedback, project, version, openData, about

    var title: LocalizedStringKey {
        switch self {
        case .alerts:   return "Оповещения и звук"
        case .speed:    return "Скорость"
        case .trip:     return "Поездка"
        case .route:    return "Маршрут"
        case .map:      return "Карта"
        case .offline:  return "Офлайн-карты"
        case .places:   return "Мои места"
        case .learning: return "Приложение учится"
        case .battery:  return "Батарея"
        case .privacy:  return "Конфиденциальность"
        case .database: return "База камер"
        case .backup:   return "Мои данные"
        case .language: return "Язык"
        case .help:     return "Помощь"
        case .feedback: return "Написать разработчику"
        case .project:  return "Страница проекта"
        case .version:  return "Версия"
        case .openData: return "Источники данных"
        case .about:    return "О приложении"
        }
    }

    var symbol: String {
        switch self {
        case .alerts:   return "bell.badge.fill"
        case .speed:    return "gauge.with.dots.needle.67percent"
        case .trip:     return "car.fill"
        case .route:    return "arrow.triangle.turn.up.right.diamond.fill"
        case .map:      return "map.fill"
        case .offline:  return "arrow.down.circle.fill"
        case .places:   return Icon.myPlaces
        case .learning: return "sparkles"
        case .battery:  return "battery.75percent"
        case .privacy:  return "hand.raised.fill"
        case .database: return "camera.fill"
        case .backup:   return "externaldrive.fill"
        case .language: return "globe"
        case .help:     return "questionmark.circle.fill"
        case .feedback: return "envelope.fill"
        case .project:  return "safari.fill"
        case .version:  return "info.circle.fill"
        case .openData: return "doc.text.fill"
        case .about:    return "info.circle.fill"
        }
    }

    /// Системные цвета iOS — те же, что у плиток в «Настройках» iPhone:
    /// плитка — опознавательный знак раздела, а не элемент палитры приложения.
    var tint: Color {
        switch self {
        case .alerts:   return Color(uiColor: .systemRed)
        case .speed:    return Color(uiColor: .systemOrange)
        case .trip:     return Color(uiColor: .systemGreen)
        case .route:    return Color(uiColor: .systemBlue)
        case .map:      return Color(uiColor: .systemTeal)
        case .offline:  return Color(uiColor: .systemIndigo)
        case .places:   return Color(uiColor: .systemBlue)
        case .learning: return Color(uiColor: .systemPurple)
        case .battery:  return Color(uiColor: .systemGreen)
        case .privacy:  return Color(uiColor: .systemBlue)
        case .database: return Color(uiColor: .systemGray)
        case .backup:   return Color(uiColor: .systemIndigo)
        case .language: return Color(uiColor: .systemBlue)
        case .help:     return Color(uiColor: .systemOrange)
        case .feedback: return Color(uiColor: .systemBlue)
        case .project:  return Color(uiColor: .systemCyan)
        case .version:  return Color(uiColor: .systemGray)
        case .openData: return Color(uiColor: .systemGray)
        case .about:    return Color(uiColor: .systemGray)
        }
    }
}

/// Плитка раздела: белый символ на цветном скруглённом квадрате.
struct SettingsIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct SettingsRow: View {
    private let item: SettingsItem
    private let value: String?
    private let accessory: String?

    init(_ item: SettingsItem, value: String? = nil, accessory: String? = nil) {
        self.item = item
        self.value = value
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 14) {
            SettingsIcon(symbol: item.symbol, tint: item.tint)
            Text(item.title)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            if let accessory {
                Image(systemName: accessory)
                    .font(.rounded(12, .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

extension View {
    /// Общий вид страницы настроек: фон приложения, заголовок посередине.
    func settingsPage(_ title: LocalizedStringKey? = nil) -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.screenBackground)
            .backport.scrollEdgeEffectStyle(.hard, for: .top)
            .modifier(SettingsTitle(title: title))
    }
}

private struct SettingsTitle: ViewModifier {
    let title: LocalizedStringKey?

    func body(content: Content) -> some View {
        if let title {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            content.navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// «Как это работает» — подробности, спрятанные за одной строкой.
///
/// Сноски страниц настроек выросли до трёх абзацев под каждой секцией
/// (снимки 12.10: экран «Поездка» — две трети серого текста). Текст нужен,
/// но не каждому и не каждый раз: строка раскрывается касанием, а сноска
/// под секцией остаётся в одно предложение. Так экран читается за взгляд, а
/// объяснение не потеряно.
struct SettingsExplainer: View {
    private let lines: [LocalizedStringKey]
    @State private var expanded = false

    init(_ lines: [LocalizedStringKey]) { self.lines = lines }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Theme.textTertiary).frame(width: 5, height: 5)
                            .padding(.top, 6)
                        Text(line)
                            .font(.rounded(14))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 6)
        } label: {
            Label("Как это работает", systemImage: "questionmark.circle")
                .font(.rounded(15))
                .foregroundStyle(Theme.accent)
        }
        .tint(Theme.accent)
    }
}

/// Сноска раздела настроек: несколько коротких мыслей вместо одного абзаца.
///
/// Три сноски этого экрана были по 927, 891 и 815 символов — примерно по
/// полтораста слов сплошняком, кеглем 12. Текст в них честный и заслуженный,
/// но в такой подаче его не читают: глаз видит серый прямоугольник и
/// проматывает. Разбиение на мысли ничего не сокращает — оно делает абзац
/// сканируемым, а это и есть разница между «написано» и «прочитано».
struct SettingsFootnote: View {
    private let lines: [LocalizedStringKey]

    init(_ lines: [LocalizedStringKey]) { self.lines = lines }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
