//
//  DesignCatalog.swift
//  RadarMap
//
//  Каталог компонентов (задача 41) — DEBUG-экран по ключу запуска
//  `-designCatalog`: все компоненты DesignSystem и ключевые составные в обеих
//  темах, с именем и правилом применения. Правила — docs/design_catalog.md.
//
//  Подписи каталога — `verbatim`: это справочник для команды, не интерфейс,
//  и в каталог строк приложения он не попадает. Заголовки самих компонентов —
//  существующие ключи, чтобы ru/uz было видно на настоящих строках.
//

#if DEBUG
import SwiftUI

struct DesignCatalogView: View {
    private enum Schemes: CaseIterable, Identifiable {
        case both, light, dark
        var id: Self { self }
        var title: String {
            switch self {
            case .both:  "Обе"
            case .light: "День"
            case .dark:  "Ночь"
            }
        }
        var list: [ColorScheme] {
            switch self {
            case .both:  [.light, .dark]
            case .light: [.light]
            case .dark:  [.dark]
            }
        }
    }

    @State private var schemes: Schemes = .both

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    Picker(selection: $schemes) {
                        ForEach(Schemes.allCases) { Text(verbatim: $0.title).tag($0) }
                    } label: {
                        Text(verbatim: "Тема")
                    }
                    .pickerStyle(.segmented)
                    .padding(16)
                    ForEach(schemes.list, id: \.self) { scheme in
                        DesignCatalogPage()
                            .environment(\.colorScheme, scheme)
                    }
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(Text(verbatim: "Каталог компонентов"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Одна тема целиком: фон страницы и все секции.
struct DesignCatalogPage: View {
    @Environment(\.colorScheme) private var scheme
    @State private var showsShortSheet = false
    @State private var tilesDeadline = Date().addingTimeInterval(3)
    @State private var chip = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text(verbatim: scheme == .dark ? "Ночь" : "День")
                .font(.rounded(22, .bold))
                .foregroundStyle(Theme.textPrimary)
            touchSection
            buttonsSection
            mapControlsSection
            reportSection
            panelsSection
            chipsSection
            signsSection
            markersSection
            trafficSection
            paletteSection
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background)
        .sheet(isPresented: $showsShortSheet) {
            MapShortSheet(title: "Пробки") {
                Text(verbatim: "Короткий лист: высота по содержимому, «Готово» справа.")
                    .font(.rounded(15))
                    .foregroundStyle(Theme.textSecondary)
            }
            .environment(\.colorScheme, scheme)
        }
    }

    // MARK: - Отклик касания

    private var touchSection: some View {
        CatalogSection("Отклик касания",
                       note: "PressableStyle(роль). Нажмите — почувствуете силу. Reduce Motion: без масштаба, только затемнение.") {
            ForEach(TouchRole.allCases, id: \.self) { role in
                CatalogItem(Self.title(role), when: Self.when(role)) {
                    Button {} label: {
                        Text(verbatim: Self.feel(role))
                            .font(.rounded(15, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: Theme.controlSize)
                            .background(Theme.surface,
                                        in: RoundedRectangle(cornerRadius: Theme.cornerControl, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Theme.cornerControl, style: .continuous)
                                .strokeBorder(Theme.stroke, lineWidth: 1))
                    }
                    .buttonStyle(PressableStyle(role))
                }
            }
        }
    }

    static func title(_ role: TouchRole) -> String {
        switch role {
        case .regular:     ".regular"
        case .primary:     ".primary"
        case .cancel:      ".cancel"
        case .choice:      ".choice"
        case .card:        ".card"
        case .row:         ".row"
        case .ownFeedback: ".ownFeedback"
        }
    }

    static func when(_ role: TouchRole) -> String {
        switch role {
        case .regular:     "Круг над картой, кнопка дока, плашка, второе действие."
        case .primary:     "Главное действие: «Поехали», «Отметить», выбор типа отметки."
        case .cancel:      "«✕», «Отмена», «Не сейчас»; Button(role: .cancel) — сам."
        case .choice:      "Чип варианта, режим, день в календаре, сегмент периода."
        case .card:        "Карточка с переходом в «Итогах»."
        case .row:         "Строка списка: без сжатия, затемнение."
        case .ownFeedback: "Действие отвечает само: «Стоп», экран оповещения, «успех»."
        }
    }

    static func feel(_ role: TouchRole) -> String {
        switch TouchResponse.of(role, reduceMotion: false).haptic {
        case .none:      "без вибрации"
        case .selection: "щелчок выбора"
        case .light:     "лёгкая"
        case .medium:    "средняя"
        case .soft:      "мягкая, глухая"
        }
    }

    // MARK: - Кнопки

    private var buttonsSection: some View {
        CatalogSection("Кнопки", note: "Высота 52, радиус cornerMedium. Жёлтая — одна на экран.") {
            CatalogItem("PrimaryButton", when: "Единственное главное действие экрана. Вибрация средняя.") {
                PrimaryButton(title: "Поехали", systemImage: "play.fill") {}
            }
            CatalogItem("PrimaryButton(tint: dangerFill)", when: "Необратимое: удалить историю. Белый текст.") {
                PrimaryButton(title: "Удалить всю историю", systemImage: "trash", tint: Theme.dangerFill) {}
            }
            CatalogItem("SecondaryButton", when: "Второе действие рядом с главным; «Отмена» — touch: .cancel.") {
                HStack(spacing: 12) {
                    SecondaryButton(title: "Отмена", touch: .cancel) {}
                    PrimaryButton(title: "Готово", systemImage: "checkmark") {}
                }
            }
        }
    }

    // MARK: - Над картой

    private var mapControlsSection: some View {
        CatalogSection("Над картой", note: "Сплошные поверхности: стекло над едущей картой запрещено.") {
            CatalogItem("CircleControl · controlCircle()", when: "Любой круг колонки карты, 44 pt.") {
                HStack(spacing: 12) {
                    CircleControl(systemName: "location.fill", tint: Theme.accent) {}
                    CircleControl(systemName: "plus") {}
                    CircleControl(systemName: "speaker.wave.2.fill") {}
                    CircleControlFace(systemName: "ellipsis")
                }
            }
            CatalogItem("IdleDock", when: "Низ простого экрана: поле «Куда едем?» 56 pt, квадрат «Итоги», чипы Дом/Работа — синим только догадка.") {
                IdleDockContent(chips: [.init(kind: .home, place: .init(lat: 41.3, lon: 69.2, title: nil),
                                              guessed: true, minutes: 25),
                                        .init(kind: .work, place: nil, guessed: false, minutes: nil)],
                                onSearch: {}, onStats: {}, onChip: { _ in }, onMyPlaces: {},
                                onStopSuggesting: {})
            }
            CatalogItem("MapShortSheet", when: "Справка над картой на 2–5 строк: высота по содержимому.") {
                SecondaryButton(title: "Пробки", systemImage: "rectangle.bottomhalf.inset.filled") {
                    showsShortSheet = true
                }
            }
        }
    }

    // MARK: - Отметка

    private var reportSection: some View {
        CatalogSection("Отметка", note: "Крупные цели для касания вслепую; у временной плашки — видимый отсчёт.") {
            CatalogItem("RoadPromptCard · выбор типа", when: "После «Отметить»: тип — .primary, «✕» — .cancel; отсчёт — в «Тренога».") {
                RoadPromptPanel {
                    RoadPromptCard(model: RoadPromptModel(
                        glyph: .filled(Icon.reportRadar, fill: Theme.action, ink: Theme.onAction),
                        question: String(localized: "Что отметить?"),
                        silence: String(format: String(localized: "промолчите — уйдёт «%@»"),
                                        ReportWords.title(.tripod)),
                        actions: [RoadPromptModel.Action(id: "x", title: String(localized: "Не отмечать"),
                                                         symbol: "xmark", touch: .cancel, narrow: true,
                                                         perform: { tilesDeadline = Date().addingTimeInterval(3) })]
                            + ReportKind.chosenOnTheGo.map { kind in
                                RoadPromptModel.Action(id: kind.rawValue, title: ReportWords.title(kind),
                                                       cameraGlyph: kind.cameraGlyph,
                                                       style: kind == .tripod ? .agree : .quiet, touch: .primary,
                                                       pressedBySilence: kind == .tripod,
                                                       perform: { tilesDeadline = Date().addingTimeInterval(3) })
                            },
                        tiles: true,
                        timer: .init(deadline: tilesDeadline, total: 3, ownTouch: true)))
                }
            }
            CatalogItem("RoadPromptCard · вопрос", when: "Синяя — согласие, тихая — второе; без красного и зелёного; «промолчите — …» всегда.") {
                RoadPromptPanel {
                    RoadPromptCard(model: RoadPromptModel(
                        glyph: .coin(CameraType.tripod.glyph, fill: CameraType.tripod.tint,
                                     ink: CameraType.tripod.glyphTint),
                        question: String(localized: "Тренога ещё стоит?"),
                        silence: String(localized: "промолчите — ничего не отправлю"),
                        actions: [
                            .init(id: "y", title: String(localized: "Стоит"), symbol: "checkmark", style: .agree,
                                  perform: {}),
                            .init(id: "n", title: String(localized: "Убрали"), symbol: "xmark", perform: {}),
                        ],
                        timer: .init(deadline: Date().addingTimeInterval(14), total: 20)))
                }
            }
        }
    }

    // MARK: - Панели и карточки

    private var panelsSection: some View {
        CatalogSection("Панели и карточки", note: "Тень — только на фоне-форме, никогда на составном виде.") {
            CatalogItem("statCard()", when: "Карточка контента «Итогов»: заливка surface и кромка, без тени.") {
                VStack(alignment: .leading, spacing: 4) {
                    SectionHeader("Итоги")
                    Text(verbatim: "128 км").font(.numeral(30, .heavy)).foregroundStyle(Theme.textPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .statCard()
            }
            CatalogItem("SolidPanel", when: "Панель поверх живой карты: сплошная, с тенью у формы.") {
                SolidPanel {
                    Text(verbatim: "Сплошная панель над картой")
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            CatalogItem("StatusBanner", when: "Состояние, требующее решения; кнопка — не подпись.") {
                StatusBanner(symbol: "wifi.slash", tint: Theme.warning,
                             title: "Карта не грузится",
                             detail: "Камеры предупреждают и без сети.",
                             action: .init(title: "Повторить") {})
            }
            CatalogItem("statePanel(_:)", when: "Блок состояния целиком: значок и текст несут смысл.") {
                Label {
                    Text(verbatim: "Поездка записывается").foregroundStyle(Theme.textPrimary)
                } icon: {
                    Image(systemName: "record.circle").foregroundStyle(Theme.success)
                }
                .font(.rounded(15, .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .statePanel(Theme.success)
            }
            CatalogItem("MetricsCard · RatingRing", when: "Цифры периода; кольцо — рейтинг 0–100.") {
                HStack(spacing: 12) {
                    RatingRing(rating: 86, animated: false)
                        .frame(width: 84, height: 84)
                    MetricsCard(items: [
                        .init(value: "128 км", label: "путь", icon: "road.lanes", tint: Theme.Icon.distance),
                        .init(value: "3 ч", label: "за рулём", icon: "clock", tint: Theme.accent),
                    ])
                }
            }
        }
    }

    // MARK: - Чипы и значки

    private var chipsSection: some View {
        CatalogSection("Чипы и значки", note: "Выбранное — accentFill с белым; синий — не главное действие.") {
            CatalogItem("Чип выбора (образец)", when: "Режим, формат, вариант: PressableStyle(.choice), высота 44.") {
                HStack(spacing: 6) {
                    ForEach(0..<3) { index in
                        Button { chip = index } label: {
                            Text(verbatim: ["Молча", "Умно", "Обо всех"][index])
                                .font(.rounded(12, .semibold))
                                .foregroundStyle(chip == index ? Theme.onAccentFill : Theme.textSecondary)
                                .frame(maxWidth: .infinity, minHeight: Theme.controlSize)
                                .background(chip == index ? AnyShapeStyle(Theme.accentFill)
                                                          : AnyShapeStyle(Theme.quietFill),
                                            in: Capsule())
                        }
                        .buttonStyle(PressableStyle(.choice))
                    }
                }
            }
            CatalogItem("IconBadge", when: "Знак строки: цвет по смыслу (Theme.Icon), круг quietFill.") {
                HStack(spacing: 12) {
                    IconBadge(symbol: "house.fill", tint: Theme.Icon.home)
                    IconBadge(symbol: "briefcase.fill", tint: Theme.Icon.work)
                    IconBadge(symbol: "clock", tint: Theme.accent)
                    IconBadge(symbol: Icon.fines, tint: Theme.warning)
                }
            }
        }
    }

    // MARK: - Знак ограничения

    private var signsSection: some View {
        CatalogSection("Знак ограничения", note: "Кегль и обводка — от диаметра; ≈ и пунктир — лимит предположен.") {
            CatalogItem("SpeedLimitSign", when: "HUD (42), карточка проезда (44).") {
                HStack(spacing: 16) {
                    SpeedLimitSign(limit: 40)
                    SpeedLimitSign(limit: 60)
                    SpeedLimitSign(limit: 100, diameter: 52)
                    SpeedLimitSign(limit: 70, isAssumed: true)
                }
            }
        }
    }

    // MARK: - Маркеры камер

    private var markersSection: some View {
        CatalogSection("Маркеры камер · вариант B", note: "Цвет значит «на вашем пути». Красный на карте — только камера.") {
            CatalogItem("CameraMarkerLook: спокойная · на пути · тревога", when: "Ни одна камера не пропадает: спокойная — тот же значок, тише.") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Self.markerTypes, id: \.self) { kind in
                        HStack(spacing: 20) {
                            CameraCoinView(glyph: kind.glyph,
                                           fill: Theme.adaptive(CameraMarkerLook.neutralDayRGB,
                                                                CameraMarkerLook.neutralNightRGB),
                                           ink: Self.calmInk, rim: Self.calmInk, side: 24)
                            CameraCoinView(glyph: kind.glyph, fill: kind.tint, ink: kind.glyphTint, side: 30)
                            ZStack {
                                Circle().fill(kind.tint.opacity(0.25)).frame(width: 56, height: 56)
                                CameraCoinView(glyph: kind.glyph, fill: kind.tint, ink: kind.glyphTint,
                                               side: 38, shadow: true)
                            }
                            CameraIcon(kind: kind, side: 30, dashedRim: true)
                        }
                    }
                    Text(verbatim: "Справа — неподтверждённая отметка водителей (пунктир).")
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private static let markerTypes: [CameraType] = [.stationaryCamera, .tripod, .dpsPost, .accident]
    private static let calmInk = Theme.adaptive(0xFFFFFF, CameraMarkerLook.calmNightInkRGB)

    // MARK: - Пробки «Сигнал»

    private var trafficSection: some View {
        CatalogSection("Пробки · «Сигнал»", note: "Днём тяжелее — темнее; «обычно» — смесь с полотном дороги.") {
            CatalogItem("TrafficPalette", when: "Слой пробок и полоса маршрута; не красный камеры.") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(1...4, id: \.self) { level in
                        let pair = TrafficPalette.level(level)
                        let usual = TrafficPalette.usual(pair)
                        HStack(spacing: 10) {
                            Capsule().fill(Theme.adaptive(pair.day, pair.night)).frame(width: 80, height: 8)
                            Capsule().fill(Theme.adaptive(usual.day, usual.night)).frame(width: 56, height: 6)
                            Text(verbatim: ["свободно", "медленно", "пробка", "стоят"][level - 1])
                                .font(.rounded(13, .medium))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Палитра

    private var paletteSection: some View {
        CatalogSection("Палитра Theme", note: "Цвета — только токены Theme; контраст проверяет PaletteTests.") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                ForEach(Self.swatches, id: \.name) { swatch in
                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(swatch.color)
                            .frame(height: 36)
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Theme.stroke, lineWidth: 1))
                        Text(verbatim: swatch.name)
                            .font(.rounded(11, .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }

    private static let swatches: [(name: String, color: Color)] = [
        ("action", Theme.action), ("accent", Theme.accent), ("accentFill", Theme.accentFill),
        ("route", Theme.route), ("danger", Theme.danger), ("warning", Theme.warning),
        ("success", Theme.success), ("textPrimary", Theme.textPrimary),
        ("textSecondary", Theme.textSecondary), ("textTertiary", Theme.textTertiary),
        ("surface", Theme.surface), ("background", Theme.background), ("quietFill", Theme.quietFill),
        ("stroke", Theme.stroke),
    ]
}

/// Секция каталога: заголовок, одна строка правила, компоненты.
private struct CatalogSection<Content: View>: View {
    let title: String
    let note: String
    @ViewBuilder var content: Content

    init(_ title: String, note: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title)
                    .font(.rounded(17, .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(verbatim: note)
                    .font(.rounded(12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
    }
}

/// Компонент с именем и правилом «когда применять».
private struct CatalogItem<Content: View>: View {
    let name: String
    let when: String
    @ViewBuilder var content: Content

    init(_ name: String, when: String, @ViewBuilder content: () -> Content) {
        self.name = name
        self.when = when
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                Text(verbatim: when)
                    .font(.rounded(12))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
    }
}

// MARK: - Превью: SE (375 pt), ru/uz, день/ночь

private struct DesignCatalogPreview: View {
    let locale: String
    let scheme: ColorScheme

    var body: some View {
        ScrollView {
            DesignCatalogPage()
        }
        .frame(width: 375)
        .background(Theme.background)
        .environment(\.locale, Locale(identifier: locale))
        .environment(\.colorScheme, scheme)
    }
}

#Preview("SE · ru · день") { DesignCatalogPreview(locale: "ru", scheme: .light) }
#Preview("SE · ru · ночь") { DesignCatalogPreview(locale: "ru", scheme: .dark) }
#Preview("SE · uz · день") { DesignCatalogPreview(locale: "uz", scheme: .light) }
#Preview("SE · uz · ночь") { DesignCatalogPreview(locale: "uz", scheme: .dark) }
#endif
