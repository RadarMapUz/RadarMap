//
//  MapPointBar.swift
//  RadarMap
//
//  Долгий тап по карте: «поеду вот сюда» — базовый жест навигатора.
//  Glass-бар с действиями для выбранной точки + быстрые чипы Дом/Работа.
//

import SwiftUI
import CoreLocation

/// Точка, выбранная долгим тапом (Identifiable — для маркера на карте).
struct MapPoint: Identifiable, Equatable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    /// Название из поиска; у точки долгого нажатия его нет.
    var title: String? = nil

    static func == (lhs: MapPoint, rhs: MapPoint) -> Bool { lhs.id == rhs.id }
}

/// Бар действий для точки: маршрут / передвижной радар / своя камера.
struct MapPointBar: View {
    var title: String? = nil
    /// nil — геопозиции нет, маршрут строить не из чего.
    let onRoute: (() -> Void)?
    let onRadar: () -> Void
    let onOwnCamera: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label {
                    if let title { Text(title).lineLimit(1) } else { Text("Точка на карте") }
                } icon: {
                    Image(systemName: "mappin.and.ellipse")
                }
                .font(.rounded(14, .semibold))
                .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.rounded(20))
                        .foregroundStyle(Theme.textTertiary)
                        .tapTarget()
                }
                .accessibilityLabel(Text("Закрыть"))
            }
            HStack(spacing: 8) {
                if let onRoute {
                    action("Маршрут сюда", "arrow.triangle.turn.up.right.circle.fill",
                           tint: Theme.accent, action: onRoute)
                }
                // Янтарь радара — заливка, а не краска текста: #F2B200 на
                // светлой панели читался 1,9:1. Значок — на кружке цвета
                // типа (как маркер на карте), подпись — обычным текстом.
                action("Радар здесь", "dot.radiowaves.left.and.right",
                       tint: Theme.textPrimary, chip: Theme.Types.radar,
                       glyph: Theme.Types.darkGlyph, action: onRadar)
                action("Своя камера", "plus.viewfinder",
                       tint: Theme.textPrimary, action: onOwnCamera)
            }
        }
        .padding(12)
        .liftedBackground(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous).strokeBorder(Theme.edgePanel, lineWidth: 1))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// `chip` — заливка кружка под значком (тогда значок — `glyph`), для
    /// цветов, которые нельзя ставить текстом. Без неё значок в цвет `tint`.
    /// Ячейка значка одной высоты в обоих случаях, иначе кнопки ряда разной
    /// высоты.
    private func action(_ title: LocalizedStringKey, _ icon: String, tint: Color,
                        chip: Color? = nil, glyph: Color = .white,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                if let chip {
                    TypeChipGlyph(symbol: icon, fill: chip, glyph: glyph)
                } else {
                    Image(systemName: icon).font(.rounded(18, .semibold))
                        .frame(height: TypeChipGlyph.side)
                }
                Text(title)
                    .font(.rounded(10, .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Theme.background,
                        in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
        }
    }
}

/// Пикер типа отметки: что впереди — радар, тренога, пост ДПС или ДТП.
/// Больше типов → живее карта: этим живут Waze и водительские чаты.
struct ReportPickerBar: View {
    let onPick: (ReportKind) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label("Что впереди?", systemImage: "eye.fill")
                    .font(.rounded(14, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.rounded(20))
                        .foregroundStyle(Theme.textTertiary)
                        .tapTarget()
                }
                .accessibilityLabel(Text("Закрыть"))
            }
            HStack(spacing: 8) {
                ForEach(ReportKind.offered) { kind in
                    Button {
                        onPick(kind)
                    } label: {
                        // Цвет типа — заливкой кружка, не краской подписи:
                        // янтарная тренога текстом на светлой панели давала
                        // 1,9:1. Кружок с глифом — тот же язык, что маркер
                        // на карте; подпись — обычный текст.
                        VStack(spacing: 4) {
                            TypeChipGlyph(symbol: kind.symbol, fill: kind.cameraType.tint,
                                          glyph: kind.cameraType.glyphTint)
                            Text(kind.title)
                                .font(.rounded(10, .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Theme.background,
                                    in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
        .padding(12)
        .liftedBackground(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous).strokeBorder(Theme.edgePanel, lineWidth: 1))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Значок типа на кружке цвета типа — как маркер камеры на карте. Цвета типов
/// подобраны как ЗАЛИВКИ (глиф на них ≥ 4,6:1), а не как текст: светлый
/// янтарь радара текстом на светлой панели нечитаем.
private struct TypeChipGlyph: View {
    static let side: CGFloat = 26
    let symbol: String
    let fill: Color
    let glyph: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.rounded(13, .bold))
            .foregroundStyle(glyph)
            .frame(width: Self.side, height: Self.side)
            .background(fill, in: Circle())
    }
}
