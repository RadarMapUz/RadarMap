//
//  AddCameraBar.swift
//  RadarMap
//
//  Нижняя панель режима добавления: своя стационарная камера или радар,
//  имя, «Добавить здесь» — сохраняется на устройстве.
//
//  «Передвижной» отсюда ушёл (5.11): к отметке радара для всех было три
//  дороги — «Радар!», «Радар здесь» у точки на карте и этот прицел, — и
//  третья ничем не отличалась от второй. Теперь «Радар!» — где я сейчас,
//  «Радар здесь» — где показал на карте, а прицел — только своя камера.
//

import SwiftUI

enum AddKind: Hashable {
    case camera, radar
}

struct AddCameraBar: View {
    let onCancel: () -> Void
    let onAdd: (AddKind, String) -> Void

    @State private var kind: AddKind = .camera
    @State private var name = ""

    var body: some View {
        GlassCard(cornerRadius: Theme.cornerLarge) {
            VStack(spacing: 14) {
                HStack {
                    Image(systemName: "scope").foregroundStyle(Theme.accent)
                    Text("Наведите центр на камеру")
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                }

                Picker("Тип", selection: $kind) {
                    Text("Камера").tag(AddKind.camera)
                    Text("Радар").tag(AddKind.radar)
                }
                .pickerStyle(.segmented)

                TextField("Название (необязательно)", text: $name)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                    .foregroundStyle(Theme.textPrimary)

                HStack(spacing: 12) {
                    // Общая вторая кнопка: самодельная была ниже соседней
                    // PrimaryButton, другого кегля и серым текстом — пара
                    // не читалась парой.
                    SecondaryButton(title: "Отмена", action: onCancel)
                    PrimaryButton(title: "Добавить здесь",
                                  systemImage: "plus",
                                  tint: Theme.accentFill) {
                        onAdd(kind, name)
                    }
                }
            }
            .padding(16)
        }
    }
}
