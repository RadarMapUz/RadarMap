//
//  AddCameraBar.swift
//  RadarMap
//
//  Нижняя панель режима добавления: тип (камера/радар/передвижной), имя, «Добавить здесь».
//  Передвижной радар уходит на сервер (виден всем водителям ~3 часа),
//  камера/радар сохраняются локально на устройстве.
//

import SwiftUI

enum AddKind: Hashable {
    case camera, radar, mobile
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
                    Text("Передвижной").tag(AddKind.mobile)
                }
                .pickerStyle(.segmented)

                if kind == .mobile {
                    Label("Отметка видна всем водителям ~3 часа", systemImage: "person.3.fill")
                        .font(.rounded(12))
                        .foregroundStyle(Theme.Types.mobile)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("Название (необязательно)", text: $name)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                        .foregroundStyle(Theme.textPrimary)
                }

                HStack(spacing: 12) {
                    Button(action: onCancel) {
                        Text("Отмена")
                            .font(.rounded(16, .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
                    }
                    PrimaryButton(title: kind == .mobile ? "Радар здесь!" : "Добавить здесь",
                                  systemImage: "plus",
                                  tint: kind == .mobile ? Theme.Types.mobile : Theme.accent) {
                        onAdd(kind, name)
                    }
                }
            }
            .padding(16)
        }
    }
}
