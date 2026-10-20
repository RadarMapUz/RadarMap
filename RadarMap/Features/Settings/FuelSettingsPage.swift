//
//  FuelSettingsPage.swift
//  RadarMap
//
//  Настройки → Поездка → «Расход и цены» (12б.3). Вид топлива уже выбран
//  строкой «Машина»; здесь — расход и цена для него и, у машины на двух
//  видах, доля пробега на втором. Цен по умолчанию нет (FuelCost).
//

import SwiftUI

struct FuelSettingsPage: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let settings = env.settings
        let fuels = settings.vehicleEnergy.fuels
        Form {
            rateSection(fuels.primary)
            if let second = fuels.second {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(format: String(localized: "Доля пробега на втором топливе: %lld%%"),
                                    Int((settings.fuelProfile.secondShare * 100).rounded())))
                        Slider(value: Binding(
                            get: { settings.fuelProfile.secondShare },
                            set: { settings.fuelProfile.secondShare = ($0 * 20).rounded() / 20 }),
                               in: 0...0.9)
                    }
                } header: {
                    Text(second.title)
                } footer: {
                    Text("Сколько примерно проезжаете не на основном топливе. Ноль — второе не учитывается.")
                }
                if settings.fuelProfile.secondShare > 0 {
                    rateSection(second)
                }
            }
            Section {
                if let cost = settings.fuelCost(meters: 10_000) {
                    LabeledContent("10 км обходятся в", value: Formatting.money(cost))
                } else {
                    Text("Укажите расход и цену — и в поездках, «Итогах» и «Дороге на работу» появится стоимость.")
                        .foregroundStyle(Theme.textSecondary)
                }
                if FuelCost.needsPriceUpdate(profile: settings.fuelProfile, now: Date()) {
                    Label("Цены не обновлялись больше двух месяцев — проверьте, не изменились ли.",
                          systemImage: "exclamationmark.circle")
                        .foregroundStyle(Theme.warning)
                }
            } footer: {
                Text("Цен по умолчанию нет: они меняются, своя цена честнее. Считается только на телефоне.")
            }
        }
        .settingsPage("Расход и цены")
    }

    private func rateSection(_ fuel: Fuel) -> some View {
        let settings = env.settings
        return Section {
            LabeledContent(String(format: String(localized: "Расход, %@ на 100 км"), fuel.unit)) {
                // Пусто, а не «0»: ноль читался как заданный расход.
                NumberField(placeholder: fuel == .electricity ? "15" : "9", decimals: true,
                            value: settings.fuelProfile.rate(fuel).per100Km) { value in
                    var rate = settings.fuelProfile.rate(fuel)
                    rate.per100Km = max(0, min(value, 100))
                    settings.fuelProfile.rates[fuel] = rate
                }
            }
            LabeledContent(String(format: String(localized: "Цена за %@, сум"), fuel.unit)) {
                NumberField(placeholder: "—", decimals: false,
                            value: settings.fuelProfile.rate(fuel).price) { value in
                    var rate = settings.fuelProfile.rate(fuel)
                    let price = max(0, min(value, 1_000_000))
                    guard price != rate.price else { return }
                    rate.price = price
                    settings.fuelProfile.rates[fuel] = rate
                    settings.fuelProfile.pricesUpdatedAt = Date()
                }
            }
        } header: {
            Text(fuel.title)
        }
    }
}

/// Число в поле настроек. Своё, а не `TextField(value:format:)`: тот отдаёт
/// значение только по «Ввод» или потере фокуса, а у цифровой клавиатуры
/// кнопки «Ввод» нет — введённая цена молча пропадала. Здесь разбор на
/// каждом нажатии; запятая и точка — обе десятичные, пробелы разрядов
/// пропускаются. Вид — по языку приложения («5 500», не «5,500»).
private struct NumberField: View {
    let placeholder: String
    let decimals: Bool
    let value: Double
    let onChange: (Double) -> Void
    @State private var text = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(decimals ? .decimalPad : .numberPad)
            .multilineTextAlignment(.trailing)
            .onAppear { text = Self.display(value, decimals: decimals) }
            .onChange(of: text) { _, newText in
                onChange(Self.parse(newText) ?? 0)
            }
    }

    static func parse(_ text: String) -> Double? {
        let cleaned = text.filter { !$0.isWhitespace }.replacingOccurrences(of: ",", with: ".")
        return Double(cleaned)
    }

    static func display(_ value: Double, decimals: Bool) -> String {
        guard value > 0 else { return "" }
        return value.formatted(.number.precision(.fractionLength(0...(decimals ? 1 : 0)))
            .grouping(decimals ? .never : .automatic)
            .locale(Formatting.numberLocale))
    }
}
