//
//  EnergyEditors.swift
//  RadarMap
//
//  Кирпичи «Машины и расходов» (21.10): карточка выбора, число с подсказкой
//  правдоподобия, запас хода с живым «реально ≈ 90 км», расход электричества.
//  Шаги мастера и листы правки из сводки собраны из одних и тех же кирпичей —
//  поэтому число, исправленное в листе, выглядит так же, как в мастере.
//
//  Всё пишется в настройки сразу (как и раньше в «Расход и цены»): у
//  цифровой клавиатуры нет «Ввода», и сохранять «по кнопке» значило бы
//  терять введённое при уходе со страницы.
//

import SwiftUI

// MARK: - Карточка выбора

/// Крупная карточка: тип машины, график и место зарядки. Выбранная — с
/// синей кромкой и галочкой; голосом — «выбрано».
struct EnergyChoiceCard: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous)
        Button(action: action) {
            HStack(spacing: 14) {
                IconBadge(symbol: symbol, tint: selected ? Theme.accent : Theme.textSecondary, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.rounded(17, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle {
                        Text(subtitle)
                            .font(.rounded(13))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: shape)
            .overlay(shape.strokeBorder(selected ? Theme.accent : Theme.stroke, lineWidth: selected ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: subtitle.map { "\(title), \($0)" } ?? title))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Заголовок блока внутри мастера и листа.
struct EnergyBlockTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.rounded(15, .semibold))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Число

/// Одно число профиля крупно: подпись, поле с единицей, обычные значения и
/// предупреждение, если цифра неправдоподобна («40 л — это на 100 км?»).
struct EnergyNumberCard: View {
    @Environment(AppEnvironment.self) private var env
    let number: EnergyNumber
    /// Своя подпись (в листе «Реальный запас» и т.п.); nil — по числу.
    var title: String? = nil

    var body: some View {
        let settings = env.settings
        let energy = settings.vehicleEnergy
        let value = number.value(in: settings.fuelProfile)
        let verdict = EnergyHints.check(value, number.hint(energy))
        VStack(alignment: .leading, spacing: 8) {
            EnergyBlockTitle(text: title ?? EnergyText.title(number, energy: energy))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                NumberField(placeholder: EnergyText.placeholder(number, energy: energy),
                            decimals: number.decimals, value: value, alignment: .leading) {
                    settings.update(number, to: $0)
                }
                    .font(.numeral(30, .bold))
                    .accessibilityLabel(Text(verbatim: EnergyText.spokenTitle(number, energy: energy)))
                Text(EnergyText.unit(number))
                    .font(.rounded(15))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                .strokeBorder(verdict == .ok ? Theme.stroke : Theme.warning, lineWidth: 1))
            if verdict != .ok {
                Label(EnergyText.warning(verdict, number: number), systemImage: "exclamationmark.circle")
                    .font(.rounded(13, .semibold))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let hint = EnergyText.hint(number, energy: energy) {
                Text(hint)
                    .font(.rounded(13))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Запас хода

/// Паспортный запас и цикл → живое «в городе реально ≈ 90 км» с правкой.
struct EnergyRangeEditor: View {
    @Environment(AppEnvironment.self) private var env
    @State private var editsReal = false

    var body: some View {
        let settings = env.settings
        let profile = settings.fuelProfile
        VStack(alignment: .leading, spacing: 18) {
            EnergyNumberCard(number: .passport)
            VStack(alignment: .leading, spacing: 8) {
                EnergyBlockTitle(text: String(localized: "Цикл из паспорта"))
                Picker(String(localized: "Цикл из паспорта"), selection: Binding(
                    get: { profile.evCycle ?? .cltc },
                    set: { cycle in
                        var updated = settings.fuelProfile
                        updated.evCycle = cycle
                        settings.fuelProfile = updated
                    })) {
                    ForEach(RangeCycle.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("У китайских машин обычно CLTC, у европейских — WLTP. Он есть в документах или на сайте производителя.")
                    .font(.rounded(13))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            realCard(profile)
            if editsReal || (profile.evRealKm ?? 0) > 0 {
                EnergyNumberCard(number: .realRange,
                                 title: String(localized: "Свой реальный запас в городе"))
            }
            Label("Зимой запас меньше на 20–30 % — учтите, если считаете по зиме.", systemImage: "snowflake")
                .font(.rounded(13))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func realCard(_ profile: FuelProfile) -> some View {
        if let real = profile.realRangeKm {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("В городе реально")
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    // «≈» не отрывается от числа: «≈ / 90 км» на двух строках
                    // читалось как обрыв (снимок 21.10).
                    Text(verbatim: "≈\u{00A0}" + EnergyText.km(real))
                        .font(.numeral(30, .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(EnergyText.realSource(profile))
                        .font(.rounded(13))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if (profile.evRealKm ?? 0) > 0 {
                    Button("Как в паспорте") { env.settings.update(.realRange, to: 0) }
                        .font(.rounded(15, .semibold))
                        .tapTarget()
                } else if !editsReal {
                    Button("Поправить") { withMotion(Motion.standard) { editsReal = true } }
                        .font(.rounded(15, .semibold))
                        .tapTarget()
                }
            }
            .statCard(padding: 14, radius: Theme.cornerMedium)
        }
    }
}

// MARK: - Расход электричества

/// Расход в кВт·ч считаем сами — из ёмкости и запаса; цифра с панели точнее.
struct EnergyElectricityEditor: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let profile = env.settings.fuelProfile
        let kWh = profile.kWhPer100
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "≈\u{00A0}" + EnergyText.per100(kWh.value, .electricity))
                    .font(.numeral(22, .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(EnergyText.kWhSource(profile))
                    .font(.rounded(13))
                    .foregroundStyle(kWh.isEstimate ? Theme.warning : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .statCard(padding: 14, radius: Theme.cornerMedium)
            .accessibilityElement(children: .combine)
            EnergyNumberCard(number: .battery)
            EnergyNumberCard(number: .per100(.electricity))
        }
    }
}
