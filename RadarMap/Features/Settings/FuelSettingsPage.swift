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
                            // Подпись и значение озвучивает сам ползунок.
                            .accessibilityHidden(true)
                        // Шаг 5 % — тот же, к которому округляет привязка: без
                        // него VoiceOver шагал на десятую часть шкалы (9 %), и
                        // число в голосе расходилось с сохранённым.
                        Slider(value: Binding(
                            get: { settings.fuelProfile.secondShare },
                            set: { settings.fuelProfile.secondShare = ($0 * 20).rounded() / 20 }),
                               in: 0...0.9, step: 0.05)
                            .accessibilityLabel(Text("Доля пробега на втором топливе"))
                            // Своё значение: системное — доля ШКАЛЫ 0…90 %, и
                            // 45 % пробега звучали бы как «50 процентов».
                            .accessibilityValue(Text(settings.fuelProfile.secondShare
                                .formatted(.percent.precision(.fractionLength(0)).locale(Formatting.numberLocale))))
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
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(String(format: String(localized: "10 километров обходятся в %@"),
                                                        Formatting.money(cost))))
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
            FieldRow(String(format: String(localized: "Расход, %@ на 100 км"), fuel.unit)) {
                // Пусто, а не «0»: ноль читался как заданный расход.
                NumberField(placeholder: fuel == .electricity ? "15" : "9", decimals: true,
                            value: settings.fuelProfile.rate(fuel).per100Km) { value in
                    var rate = settings.fuelProfile.rate(fuel)
                    rate.per100Km = max(0, min(value, 100))
                    settings.fuelProfile.rates[fuel] = rate
                }
                // Поле само по себе озвучивалось подсказкой «9»: что в него
                // вводить и в чём, слышно не было. И единица словом —
                // «м³» голосом не читается.
                .accessibilityLabel(Text(fuel.spokenRateLabel))
            }
            FieldRow(String(format: String(localized: "Цена за %@, сум"), fuel.unit)) {
                NumberField(placeholder: "—", decimals: false,
                            value: settings.fuelProfile.rate(fuel).price) { value in
                    var rate = settings.fuelProfile.rate(fuel)
                    let price = max(0, min(value, 1_000_000))
                    guard price != rate.price else { return }
                    rate.price = price
                    settings.fuelProfile.rates[fuel] = rate
                    settings.fuelProfile.pricesUpdatedAt = Date()
                }
                .accessibilityLabel(Text(fuel.spokenPriceLabel))
            }
        } header: {
            Text(fuel.title)
        }
    }
}

/// Подпись и поле. Своя строка, а не LabeledContent: на крупном (не
/// специальном) шрифте поле забирало полстроки, и «Sarf, 100 km ga m³»
/// обрезалось до «Sarf, 100 km g…» — пропадала единица, ради которой
/// подпись; разрешить перенос LabeledContent не дал — вторая строка
/// срезалась высотой строки (снимки 14.6). Здесь подпись переносится, а
/// на специальных размерах поле уходит под неё, как у системных строк.
/// Голосом подпись читает само поле — текст слева VoiceOver пропускает.
struct FieldRow<Field: View>: View {
    let label: String
    @ViewBuilder let field: () -> Field
    @Environment(\.dynamicTypeSize) private var typeSize

    init(_ label: String, @ViewBuilder field: @escaping () -> Field) {
        self.label = label
        self.field = field
    }

    var body: some View {
        let text = Text(label)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                text
                field().frame(maxWidth: .infinity, alignment: .trailing)
            }
        } else {
            HStack(spacing: 12) {
                text.layoutPriority(1)
                field()
            }
        }
    }
}

private extension Fuel {
    /// Подписи полей для VoiceOver — единица полным словом.
    var spokenRateLabel: String {
        switch self {
        case .petrol, .propane: return String(localized: "Расход, литров на 100 километров")
        case .methane:          return String(localized: "Расход, кубометров на 100 километров")
        case .electricity:      return String(localized: "Расход, киловатт-часов на 100 километров")
        }
    }

    var spokenPriceLabel: String {
        switch self {
        case .petrol, .propane: return String(localized: "Цена за литр, в сумах")
        case .methane:          return String(localized: "Цена за кубометр, в сумах")
        case .electricity:      return String(localized: "Цена за киловатт-час, в сумах")
        }
    }
}

/// Число в поле настроек. Своё, а не `TextField(value:format:)`: тот отдаёт
/// значение только по «Ввод» или потере фокуса, а у цифровой клавиатуры
/// кнопки «Ввод» нет — введённая цена молча пропадала. Здесь разбор на
/// каждом нажатии; запятая и точка — обе десятичные, пробелы разрядов
/// пропускаются. Вид — по языку приложения («5 500», не «5,500»).
///
/// Два вида: «пусто = 0» (расход, цена) и «пусто ≠ 0» (`optional`, интервалы
/// обслуживания: пусто — как по умолчанию, ноль — не учитывать).
struct NumberField: View {
    let placeholder: String
    let decimals: Bool
    private let value: Double?
    /// Ноль показывается пустым полем (расход, цена).
    private let zeroIsEmpty: Bool
    private let onChange: (Double?) -> Void
    @State private var text = ""

    init(placeholder: String, decimals: Bool, value: Double, onChange: @escaping (Double) -> Void) {
        self.placeholder = placeholder
        self.decimals = decimals
        self.value = value
        zeroIsEmpty = true
        self.onChange = { onChange($0 ?? 0) }
    }

    init(placeholder: String, decimals: Bool, optional value: Double?,
         onChange: @escaping (Double?) -> Void) {
        self.placeholder = placeholder
        self.decimals = decimals
        self.value = value
        zeroIsEmpty = false
        self.onChange = onChange
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(decimals ? .decimalPad : .numberPad)
            .multilineTextAlignment(.trailing)
            // Подпись слева переносится и берёт ширину первой — полю
            // оставлен минимум под «12 500».
            .frame(minWidth: 80)
            .onAppear { text = Self.display(value, decimals: decimals, zeroIsEmpty: zeroIsEmpty) }
            .onChange(of: text) { _, newText in
                onChange(Self.parse(newText))
            }
    }

    static func parse(_ text: String) -> Double? {
        let cleaned = text.filter { !$0.isWhitespace }.replacingOccurrences(of: ",", with: ".")
        return Double(cleaned)
    }

    static func display(_ value: Double?, decimals: Bool, zeroIsEmpty: Bool = true) -> String {
        guard let value, value > 0 || (!zeroIsEmpty && value == 0) else { return "" }
        return value.formatted(.number.precision(.fractionLength(0...(decimals ? 1 : 0)))
            .grouping(decimals ? .never : .automatic)
            .locale(Formatting.numberLocale))
    }
}
