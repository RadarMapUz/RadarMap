//
//  AddCameraBar.swift
//  RadarMap
//
//  Нижняя панель прицела: что ставим (AddPointKind) и кто это увидит — своя
//  камера навсегда и только у вас или тренога для всех водителей.
//

import SwiftUI

struct AddCameraBar: View {
    /// Зовётся в body бара, а не экрана: центр карты и своя точка меняются часто.
    let tripod: () -> TripodAvailability
    let onCancel: () -> Void
    let onAdd: (AddPointKind, String) -> Void

    @State private var kind: AddPointKind = .speedCamera
    @State private var name = ""
    /// Поле названия свёрнуто в «+ Название»: оно нужно редко, а место над
    /// панелью — это карта с прицелом.
    @State private var naming = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        let tripodState = tripod()
        GlassCard(cornerRadius: Theme.cornerLarge) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind == .tripod ? String(localized: "Где стоит тренога?")
                                         : String(localized: "Где стоит камера?"))
                        .font(.dense(17, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Подвиньте карту, чтобы прицел встал на неё")
                        .font(.dense(13))
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityElement(children: .combine)

                HStack(spacing: 8) {
                    ForEach(AddPointKind.allCases) { option in
                        tile(option, tripod: tripodState)
                    }
                }

                HStack(spacing: 8) {
                    Text(Self.consequence(kind, tripod: tripodState))
                        .font(.dense(12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if kind.isOwnCamera && !naming {
                        Button {
                            withMotion { naming = true }
                            nameFocused = true
                        } label: {
                            Label("Название", systemImage: "plus")
                                .font(.dense(13, .semibold))
                                .foregroundStyle(Theme.accent)
                                .tapTarget()
                        }
                        .accessibilityLabel(Text("Добавить название"))
                    }
                }

                if kind.isOwnCamera && naming {
                    TextField("Название (необязательно)", text: $name)
                        .focused($nameFocused)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12)
                        .frame(minHeight: Theme.controlSize)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                        .foregroundStyle(Theme.textPrimary)
                }

                HStack(spacing: 12) {
                    SecondaryButton(title: "Отмена", touch: .cancel, action: onCancel)
                    // Отклик — по итогу сохранения или отметки (MapScreen.addPoint).
                    PrimaryButton(title: kind == .tripod ? LocalizedStringKey("Отметить треногу")
                                                         : LocalizedStringKey("Сохранить камеру"),
                                  systemImage: kind == .tripod ? "exclamationmark.triangle.fill" : "checkmark",
                                  tint: Theme.accentFill,
                                  touch: .ownFeedback) {
                        onAdd(kind, kind.isOwnCamera ? name : "")
                    }
                    .disabled(kind == .tripod && !tripodState.isAvailable)
                }
            }
            .padding(14)
            .typeDensity(.dense)
        }
    }

    /// Плитка ряда: значок и короткое имя; что будет — строкой под рядом.
    /// Тренога выбирается и там, где её сейчас не поставить: прицел можно
    /// довести до места, а кнопка честно ждёт.
    private func tile(_ option: AddPointKind, tripod: TripodAvailability) -> some View {
        let selected = option == kind
        let open = option != .tripod || tripod.isAvailable
        let shape = RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
        return Button {
            withMotion { kind = option }
        } label: {
            VStack(spacing: 4) {
                // Пунктирный кант — так свежая отметка водителей и встанет на карте.
                CameraIcon(kind: option.cameraType, side: 26, dashedRim: option == .tripod)
                    .opacity(open ? 1 : 0.55)
                Text(Self.shortTitle(option))
                    .font(.dense(13, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: Theme.controlSize)
            .background(Theme.surface, in: shape)
            .overlay(shape.strokeBorder(selected ? Theme.accent : Theme.stroke, lineWidth: selected ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(Text(Self.title(option)))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private static func title(_ option: AddPointKind) -> String {
        switch option {
        case .speedCamera:  return String(localized: "Камера скорости")
        case .signalCamera: return String(localized: "Камера на светофоре")
        case .tripod:       return ReportWords.title(.tripod)
        }
    }

    private static func shortTitle(_ option: AddPointKind) -> String {
        switch option {
        case .speedCamera:  return String(localized: "Скорость")
        case .signalCamera: return String(localized: "Светофор")
        case .tripod:       return ReportWords.title(.tripod)
        }
    }

    private static func consequence(_ option: AddPointKind, tripod: TripodAvailability) -> String {
        switch option {
        case .speedCamera:  return String(localized: "Меряет скорость · только у вас")
        case .signalCamera: return String(localized: "Светофор и полосы · только у вас")
        case .tripod:
            if let passed = tripod.observedAt {
                return String(format: String(localized: "Вы проезжали здесь в %@ · увидят все водители"),
                              Formatting.clock(passed))
            }
            return tripod.note ?? String(localized: "Увидят все водители · исчезнет сама")
        }
    }
}

extension TripodAvailability {
    /// Почему отметку для всех пальцем сейчас не поставить; nil — можно.
    var note: String? {
        switch self {
        case .available, .passedBy: return nil
        case .tooFar:
            return String(localized: "Только рядом с вами или там, где вы проезжали за последние 3 часа")
        case .noPosition:
            return String(localized: "Нужна геопозиция — или место, где вы проезжали за последние 3 часа")
        case .reportsOff: return String(localized: "Отметки водителей сейчас выключены")
        }
    }
}

/// Прицел постановки: в середине видимой карты (AddPointAim) — там же, откуда
/// движок берёт координату. Точка в центре — ровно место установки.
struct AddPointCrosshair: View {
    let frame: MapFrameState

    private static let ring: CGFloat = 46
    private static let dot: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let aim = AddPointAim.point(width: geo.size.width, height: geo.size.height, insets: frame.insets)
            mark
                .position(aim)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Белый кант под синим — заметно и на светлой карте, и на ночной.
    private var mark: some View {
        ZStack {
            Circle()
                .stroke(Theme.onAccentFill, lineWidth: 6)
                .shadow(color: Theme.panelShadow, radius: 3, y: 1)
            Circle()
                .stroke(Theme.accentFill, lineWidth: 3)
            ForEach(0..<4, id: \.self) { quarter in
                Capsule()
                    .fill(Theme.accentFill)
                    .overlay(Capsule().stroke(Theme.onAccentFill, lineWidth: 1))
                    .frame(width: 3, height: 12)
                    .offset(y: -Self.ring / 2)
                    .rotationEffect(.degrees(Double(quarter) * 90))
            }
            Circle()
                .fill(Theme.accentFill)
                .overlay(Circle().stroke(Theme.onAccentFill, lineWidth: 2))
                .frame(width: Self.dot, height: Self.dot)
                .shadow(color: Theme.panelShadow, radius: 2)
        }
        .frame(width: Self.ring, height: Self.ring)
    }
}
