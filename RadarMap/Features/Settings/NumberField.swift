//
//  NumberField.swift
//  RadarMap
//
//  Число в настройках: подпись с полем (FieldRow) и само поле (NumberField).
//  Жили в странице «Расход и цены» (12б.3), которую 21.10 сменил раздел
//  «Машина и расходы»; поля остались общими — обслуживание, расходы.
//

import SwiftUI

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
    /// Справа — в строке формы; слева — в крупной карточке мастера.
    var alignment: TextAlignment = .trailing
    private let value: Double?
    /// Ноль показывается пустым полем (расход, цена).
    private let zeroIsEmpty: Bool
    private let onChange: (Double?) -> Void
    @State private var text = ""

    init(placeholder: String, decimals: Bool, value: Double, alignment: TextAlignment = .trailing,
         onChange: @escaping (Double) -> Void) {
        self.placeholder = placeholder
        self.decimals = decimals
        self.alignment = alignment
        self.value = value
        zeroIsEmpty = true
        self.onChange = { onChange($0 ?? 0) }
    }

    init(placeholder: String, decimals: Bool, optional value: Double?, alignment: TextAlignment = .trailing,
         onChange: @escaping (Double?) -> Void) {
        self.placeholder = placeholder
        self.decimals = decimals
        self.alignment = alignment
        self.value = value
        zeroIsEmpty = false
        self.onChange = onChange
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(decimals ? .decimalPad : .numberPad)
            .multilineTextAlignment(alignment)
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
