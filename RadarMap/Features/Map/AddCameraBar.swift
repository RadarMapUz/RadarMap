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

    var body: some View {
        let tripodState = tripod()
        GlassCard(cornerRadius: Theme.cornerLarge) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind == .tripod ? String(localized: "Где стоит тренога?")
                                         : String(localized: "Где стоит камера?"))
                        .font(.dense(17, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Наведите на неё центр карты")
                        .font(.dense(13))
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityElement(children: .combine)

                VStack(spacing: 8) {
                    ForEach(AddPointKind.allCases) { option in
                        tile(option, tripod: tripodState)
                    }
                }

                if kind.isOwnCamera {
                    TextField("Название (необязательно)", text: $name)
                        .textFieldStyle(.plain)
                        .padding(12)
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
            .padding(16)
            .typeDensity(.dense)
        }
    }

    private func tile(_ option: AddPointKind, tripod: TripodAvailability) -> some View {
        let selected = option == kind
        let open = option != .tripod || tripod.isAvailable
        let shape = RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
        return Button {
            withMotion { kind = option }
        } label: {
            HStack(spacing: 12) {
                // Пунктирный кант — так свежая отметка водителей и встанет на карте.
                CameraIcon(kind: option.cameraType, side: 30, dashedRim: option == .tripod)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title(option))
                        .font(.dense(15, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(Self.consequence(option, tripod: tripod))
                        .font(.dense(12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.dense(20))
                    .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: Theme.controlSize, alignment: .leading)
            .background(Theme.surface, in: shape)
            .overlay(shape.strokeBorder(selected ? Theme.accent : Theme.stroke, lineWidth: selected ? 2 : 1))
            .contentShape(shape)
            .opacity(open ? 1 : 0.55)
        }
        .buttonStyle(PressableStyle())
        .disabled(!open && !selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private static func title(_ option: AddPointKind) -> String {
        switch option {
        case .speedCamera:  return String(localized: "Камера скорости")
        case .signalCamera: return String(localized: "Камера на светофоре")
        case .tripod:       return ReportWords.title(.tripod)
        }
    }

    private static func consequence(_ option: AddPointKind, tripod: TripodAvailability) -> String {
        switch option {
        case .speedCamera:  return String(localized: "Меряет скорость · только у вас")
        case .signalCamera: return String(localized: "Светофор и полосы · только у вас")
        case .tripod:
            return tripod.note ?? String(localized: "Увидят все водители · исчезнет сама")
        }
    }
}

extension TripodAvailability {
    /// Почему отметку для всех пальцем сейчас не поставить; nil — можно.
    var note: String? {
        switch self {
        case .available:  return nil
        case .tooFar:
            return String(format: String(localized: "Только рядом с вами — до %@"),
                          Formatting.distance(AppConfig.addTripodMaxDistanceMeters))
        case .noPosition: return String(localized: "Нужна ваша геопозиция — отметка ставится рядом")
        case .reportsOff: return String(localized: "Отметки водителей сейчас выключены")
        }
    }
}
