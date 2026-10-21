//
//  EnergyWizard.swift
//  RadarMap
//
//  Первый вход в «Машину и расходы» (21.10, 21.3): мастер на 3–5 шагов
//  крупными карточками — тип → (для розетки) запас и зарядка → расход →
//  цены. Каждый шаг можно пропустить. Польза — уже со второго шага:
//  внизу живая строка «Ваш обычный день: 34 км — всё на электричестве»,
//  деньги в ней появляются, когда добавлены цены.
//
//  Числа пишутся в настройки сразу: ушёл со страницы посреди мастера —
//  введённое не пропало, а сводка покажет, чего не хватает.
//

import SwiftUI

enum EnergyStep: Int, CaseIterable, Sendable {
    case type, range, charging, consumption, prices

    /// Шаги для машины: запас и зарядка — только тем, у кого есть розетка.
    static func steps(for energy: VehicleEnergy) -> [EnergyStep] {
        energy.plugs ? [.type, .range, .charging, .consumption, .prices] : [.type, .consumption, .prices]
    }

    func title(_ energy: VehicleEnergy) -> String {
        switch self {
        case .type: return String(localized: "Какая у вас машина?")
        case .range: return String(localized: "Сколько проезжает на электричестве?")
        case .charging:
            return energy == .hybrid ? String(localized: "Как вы заряжаете?") : String(localized: "Где вы заряжаете?")
        case .consumption: return String(localized: "Сколько тратит машина")
        case .prices: return String(localized: "Цены")
        }
    }

    func subtitle(_ energy: VehicleEnergy) -> String {
        switch self {
        case .type:
            return String(localized: "От этого зависит, как считать расходы и какие заправки показывать в CarPlay.")
        case .range:
            return String(localized: "Запас из паспорта, а реальный в городе посчитаем сами — и его можно поправить.")
        case .charging:
            return energy == .hybrid
                ? String(localized: "Заряд тратится первым, потом — бензин. Поэтому важно, как часто батарея снова полная.")
                : String(localized: "Дома свет в разы дешевле, чем на станции.")
        case .consumption:
            switch energy {
            case .hybrid:
                return String(localized: "Бензин — в гибридном режиме, когда батарея села. Электричество посчитаем из запаса.")
            case .electric:
                return String(localized: "Расход в кВт·ч посчитаем из ёмкости батареи — или введите цифру с панели.")
            default:
                return String(localized: "Средний расход — из бортового компьютера или по опыту.")
            }
        case .prices:
            return String(localized: "Своя цена честнее средней. Можно пропустить — километры видны и без цен.")
        }
    }
}

struct EnergyWizard: View {
    @Environment(AppEnvironment.self) private var env
    let onFinish: () -> Void
    @State private var step: EnergyStep = .type

    var body: some View {
        let energy = env.settings.vehicleEnergy
        let steps = EnergyStep.steps(for: energy)
        let index = steps.firstIndex(of: step) ?? 0
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(energy: energy, index: index, count: steps.count)
                        .id("top")
                    content(energy: energy)
                    if step != .type {
                        EnergyExamples(compact: true)
                    }
                }
                .padding(16)
            }
            .onChange(of: step) { _, _ in proxy.scrollTo("top", anchor: .top) }
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { bottomBar(steps: steps, index: index) }
        #if DEBUG
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-energyStep"), i + 1 < args.count,
               let raw = Int(args[i + 1]), let target = EnergyStep(rawValue: raw) {
                step = target
            }
        }
        #endif
    }

    private func header(energy: VehicleEnergy, index: Int, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(format: String(localized: "Шаг %1$lld из %2$lld"), index + 1, count))
                .font(.rounded(13, .semibold))
                .foregroundStyle(Theme.accent)
            Text(step.title(energy))
                .font(.rounded(26, .bold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(step.subtitle(energy))
                .font(.rounded(15))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func content(energy: VehicleEnergy) -> some View {
        switch step {
        case .type:
            EnergyTypePicker { advance(from: .type) }
        case .range:
            EnergyRangeEditor()
        case .charging:
            if energy == .hybrid {
                EnergyBlockTitle(text: String(localized: "Как часто батарея снова полная"))
                EnergyScheduleEditor()
                EnergyBlockTitle(text: String(localized: "Где заряжаете"))
                    .padding(.top, 6)
            }
            EnergyPlaceEditor()
        case .consumption:
            EnergyConsumptionEditor()
        case .prices:
            EnergyPricesEditor()
        }
    }

    private func bottomBar(steps: [EnergyStep], index: Int) -> some View {
        let last = index >= steps.count - 1
        // Тип ключа — явно: тернарник литералов иначе выводится в String и
        // уходит в кнопку без перевода.
        let primary: LocalizedStringKey = last ? "Готово" : "Далее"
        let skip: LocalizedStringKey = last ? "Пропустить и закончить" : "Пропустить"
        return VStack(spacing: 4) {
            PrimaryButton(title: primary) {
                if last { onFinish() } else { advance(from: step) }
            }
            HStack {
                if index > 0 {
                    Button("Назад") { go(to: steps[index - 1]) }
                        .tapTarget()
                }
                Spacer()
                Button(skip) {
                    if last { onFinish() } else { advance(from: step) }
                }
                .tapTarget()
            }
            .font(.rounded(15, .semibold))
            .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .background(Theme.background.ignoresSafeArea(edges: .bottom))
    }

    /// Следующий шаг — по типу, выбранному сейчас (тип мог только что смениться).
    private func advance(from current: EnergyStep) {
        let steps = EnergyStep.steps(for: env.settings.vehicleEnergy)
        guard let index = steps.firstIndex(of: current), index + 1 < steps.count else {
            onFinish()
            return
        }
        go(to: steps[index + 1])
    }

    private func go(to target: EnergyStep) {
        withMotion(Motion.standard) { step = target }
    }
}

// MARK: - Расход и цены — общие с листами правки

/// Расход для машины: бензин, газ с долей, электричество — что нужно этому типу.
struct EnergyConsumptionEditor: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let settings = env.settings
        let energy = settings.vehicleEnergy
        VStack(alignment: .leading, spacing: 18) {
            switch energy {
            case .cng, .lpg:
                EnergyNumberCard(number: .per100(energy.fuels.primary))
                EnergyGasShareEditor()
                if settings.fuelProfile.secondShare > 0 {
                    EnergyNumberCard(number: .per100(.petrol))
                }
            case .electric:
                EnergyElectricityEditor()
            case .hybrid:
                EnergyNumberCard(number: .per100(.petrol))
                EnergyBlockTitle(text: String(localized: "Электричество"))
                EnergyElectricityEditor()
            case .fuel, .hev:
                EnergyNumberCard(number: .per100(.petrol))
            }
        }
    }
}

/// Цены, нужные этой машине, — по топливу и месту зарядки.
struct EnergyPricesEditor: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let settings = env.settings
        VStack(alignment: .leading, spacing: 18) {
            ForEach(EnergyNumber.prices(for: settings.vehicleEnergy, profile: settings.fuelProfile)) { number in
                EnergyNumberCard(number: number)
            }
            Text("Цен по умолчанию нет: они меняются, своя цена честнее. Через два месяца приложение напомнит их проверить.")
                .font(.rounded(13))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
