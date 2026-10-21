//
//  EnergySettingsPage.swift
//  RadarMap
//
//  Настройки → «Машина и расходы» (21.10, 21.3) — раздел верхнего уровня.
//  До 21.10 это была строка «Расход и цены» в глубине «Поездки»: не найти,
//  и ничего не видно, пока не заполнено всё.
//
//  Первый вход — мастер (EnergyWizard). Дальше — сводка: тип с иконкой,
//  «Ваш обычный день: 34 км — всё на электричестве ≈ 3 400 сум» по своим
//  поездкам, длинная поездка, строки с цифрами (тап меняет одну цифру),
//  «Как посчитано» и свежесть цен. Считает EnergySplit; страница только
//  показывает.
//

import SwiftUI

/// Что правится листом из строки сводки.
enum EnergyPart: Hashable, Identifiable {
    case type, range, schedule, place, electricity, gasShare, check
    case number(EnergyNumber)

    var id: String {
        switch self {
        case .number(let number): return number.id
        default: return String(describing: self)
        }
    }
}

struct EnergySettingsPage: View {
    @Environment(AppEnvironment.self) private var env
    @State private var editing: EnergyPart?
    /// «Пройти по шагам» из сводки — мастер поверх готового профиля.
    @State private var wizard = false

    var body: some View {
        let settings = env.settings
        Group {
            if wizard || (settings.fuelProfile.setupDone != true && settings.fuelProfile.isBlank) {
                EnergyWizard {
                    var profile = settings.fuelProfile
                    profile.setupDone = true
                    settings.fuelProfile = profile
                    withMotion(Motion.standard) { wizard = false }
                }
            } else {
                summary
            }
        }
        .settingsPage("Машина и расходы")
        .sheet(item: $editing) { part in
            EnergyEditSheet(part: part)
        }
        .onAppear {
            env.usage.noteScreen("energy")
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-energyWizard") { wizard = true }
            if let i = args.firstIndex(of: "-energyEdit"), i + 1 < args.count {
                Task {
                    await Task.pause(seconds: 0.8)
                    editing = Self.debugPart(args[i + 1])
                }
            }
            #endif
        }
    }

    #if DEBUG
    private static func debugPart(_ name: String) -> EnergyPart? {
        switch name {
        case "type": return .type
        case "range": return .range
        case "schedule": return .schedule
        case "place": return .place
        case "electricity": return .electricity
        case "check": return .check
        case "petrol": return .number(.per100(.petrol))
        default: return nil
        }
    }
    #endif

    // MARK: - Сводка

    private var summary: some View {
        let settings = env.settings
        let energy = settings.vehicleEnergy
        let profile = settings.fuelProfile
        return ScrollViewReader { proxy in
        Form {
            if settings.needsHybridQuestion {
                Section {
                    // «Да» без запаса хода — сразу к запасу: без него доля
                    // на электричестве осталась бы прежней угаданной.
                    HybridPlugQuestion { plugs in
                        if plugs, settings.fuelProfile.realRangeKm == nil { editing = .range }
                    }
                }
            }
            Section {
                Button { editing = .type } label: { typeRow(energy) }
                    .tint(Theme.textPrimary)
            }
            Section {
                EnergyExamples(compact: false)
            } header: {
                Text("Сколько стоит дорога")
            }
            Section {
                machineRows(energy: energy, profile: profile)
            } header: {
                Text("Машина")
            }
            .id("machine")
            Section {
                ForEach(EnergyNumber.prices(for: energy, profile: profile)) { number in
                    valueRow(EnergyText.title(number, energy: energy), value: priceValue(number, profile)) {
                        editing = .number(number)
                    }
                }
                if FuelCost.needsPriceUpdate(profile: profile, now: Date()) {
                    Label("Цены не обновлялись больше двух месяцев — проверьте, не изменились ли.",
                          systemImage: "exclamationmark.circle")
                        .foregroundStyle(Theme.warning)
                }
            } header: {
                Text("Цены")
            } footer: {
                Text(priceFooter(profile))
            }
            .id("prices")
            Section {
                EnergyFormula(lines: EnergyText.explanation(profile: profile, energy: energy,
                                                            model: env.energyLedger.model))
            }
            .id("formula")
            Section {
                if energy != .fuel {
                    Button { editing = .check } label: {
                        Label("Сверить с машиной", systemImage: "gauge.with.dots.needle.33percent")
                    }
                }
                Button { withMotion(Motion.standard) { wizard = true } } label: {
                    Label("Пройти настройку по шагам", systemImage: "list.bullet.clipboard")
                }
                NavigationLink {
                    MaintenancePage()
                } label: {
                    LabeledContent {
                        Text(MaintenanceText.summary(env.maintenance.states(),
                                                     hasOdometer: env.maintenance.odometerKm != nil))
                    } label: {
                        Label("Обслуживание", systemImage: "wrench.and.screwdriver.fill")
                    }
                }
            } footer: {
                Text("Пробег, расход и цены никуда не уходят — считается только на телефоне.")
            }
            .id("actions")
        }
        #if DEBUG
        .onAppear {
            // Снимки без касаний: `-energyScroll machine|prices|formula|actions`.
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-energyScroll"), i + 1 < args.count {
                Task {
                    await Task.pause(seconds: 1)
                    proxy.scrollTo(args[i + 1], anchor: .top)
                }
            }
        }
        #endif
        }
    }

    private func typeRow(_ energy: VehicleEnergy) -> some View {
        HStack(spacing: 14) {
            IconBadge(symbol: EnergyText.symbol(energy), size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(energy.title)
                    .font(.rounded(17, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(EnergyText.subtitle(energy))
                    .font(.rounded(13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            // Шеврон, а не слово «Изменить»: узбекское «Oʻzgartirish» на
            // крупном шрифте отнимало полстроки, и тип ломался на две.
            Image(systemName: "chevron.right")
                .font(.rounded(12, .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(energy.title), \(EnergyText.subtitle(energy))"))
        .accessibilityHint(Text("Изменить тип машины"))
    }

    @ViewBuilder
    private func machineRows(energy: VehicleEnergy, profile: FuelProfile) -> some View {
        if energy.plugs {
            valueRow(String(localized: "Запас на электричестве"),
                     value: profile.realRangeKm.map { "≈\u{00A0}" + EnergyText.km($0) }
                        ?? String(localized: "не указан")) { editing = .range }
            let kWh = profile.kWhPer100
            valueRow(String(localized: "Расход электричества"),
                     value: kWh.isEstimate
                        ? String(format: String(localized: "%@ · оценка"), EnergyText.per100Short(kWh.value, .electricity))
                        : EnergyText.per100Short(kWh.value, .electricity)) { editing = .electricity }
        }
        if energy == .hybrid {
            valueRow(String(localized: "Как заряжаете"),
                     value: EnergyText.schedule(profile.chargeSchedule ?? .nightly)) { editing = .schedule }
        }
        if energy.plugs {
            valueRow(String(localized: "Где заряжаете"),
                     value: EnergyText.place(profile.chargePlace ?? .home)) { editing = .place }
        }
        ForEach(EnergyNumber.consumption(for: energy, profile: profile)) { number in
            valueRow(EnergyText.title(number, energy: energy),
                     value: profile.rate(Self.fuel(of: number)).per100Km > 0
                        ? EnergyText.per100Short(number.value(in: profile), Self.fuel(of: number))
                        : String(localized: "не указан")) { editing = .number(number) }
            if case .per100(let fuel) = number, fuel != .petrol {
                valueRow(String(localized: "Пути на бензине"), value: EnergyText.percent(profile.secondShare)) {
                    editing = .gasShare
                }
            }
        }
    }

    private static func fuel(of number: EnergyNumber) -> Fuel {
        if case .per100(let fuel) = number { return fuel }
        return .petrol
    }

    private func priceValue(_ number: EnergyNumber, _ profile: FuelProfile) -> String {
        let value = number.value(in: profile)
        guard value > 0 else { return String(localized: "не указана") }
        return String(format: String(localized: "%1$@ за %2$@"), Formatting.money(value), EnergyText.priceUnit(number))
    }

    private func priceFooter(_ profile: FuelProfile) -> String {
        guard let updated = profile.pricesUpdatedAt else {
            return String(localized: "Цен по умолчанию нет: они меняются, своя цена честнее.")
        }
        return String(format: String(localized: "Обновлены %@. Через два месяца приложение напомнит проверить."),
                      updated.formatted(.dateTime.day().month(.wide).locale(Formatting.numberLocale)))
    }

    /// Строка «подпись — значение ›»: тап открывает лист одного числа.
    /// Значение не ломается по буквам: не влезает рядом — уходит под подпись
    /// (снимок 21.10: «5,5 / л/100 / км» столбиком).
    private func valueRow(_ title: String, value: String, action: @escaping () -> Void) -> some View {
        let label = Text(title)
            .foregroundStyle(Theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
        let shown = Text(value)
            .foregroundStyle(Theme.textSecondary)
        return Button(action: action) {
            HStack(spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        label
                        Spacer(minLength: 8)
                        shown.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        label
                        shown.fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Image(systemName: "chevron.right")
                    .font(.rounded(12, .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(title), \(value)"))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Вопрос про розетку

/// Гибрид, выбранный до 21.10, — один ясный вопрос, пока нет ответа.
struct HybridPlugQuestion: View {
    @Environment(AppEnvironment.self) private var env
    var onAnswer: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                IconBadge(symbol: EnergyText.symbol(.hybrid), size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ваш гибрид заряжается от розетки?")
                        .font(.rounded(17, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("С розеткой — сначала едет на электричестве, без розетки — только на бензине. От этого зависят расходы и плитка «Зарядка» в CarPlay.")
                        .font(.rounded(13))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                PrimaryButton(title: "Да, от розетки") {
                    env.settings.answerHybridPlug(true)
                    onAnswer(true)
                }
                SecondaryButton(title: "Нет") {
                    env.settings.answerHybridPlug(false)
                    onAnswer(false)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Как посчитано

/// «Как посчитано» — раскрывается формулой; сумма проверяется глазами.
struct EnergyFormula: View {
    let lines: [String]
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Theme.textTertiary).frame(width: 5, height: 5)
                            .padding(.top, 6)
                            .accessibilityHidden(true)
                        Text(line)
                            .font(.rounded(14))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 6)
        } label: {
            Label("Как посчитано", systemImage: "function")
                .font(.rounded(15))
                .foregroundStyle(Theme.accent)
        }
        .tint(Theme.accent)
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-energyFormula") { expanded = true }
        }
        #endif
    }
}
