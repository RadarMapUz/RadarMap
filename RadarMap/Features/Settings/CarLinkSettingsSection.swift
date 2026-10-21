//
//  CarLinkSettingsSection.swift
//  RadarMap
//
//  «Только в машине» (26.2): выбор устройства машины из подключённых сейчас
//  и одноразовое предложение режима тем, у кого CarPlay уже подключался.
//

import SwiftUI

/// Предложение «Начинать поездку только в машине?» — один раз, не молча.
struct CarOnlyOfferSection: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        // Ревизия — подписка на ответ: сами флаги лежат в Storage.
        let _ = env.carOnlyOfferRevision
        if env.offersCarOnlyMode {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Начинать поездку только в машине?", systemImage: "car.fill")
                        .font(.rounded(17, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Вы уже подключали CarPlay. Поездка начнётся, когда телефон подключится к машине, и закончится, когда отключится. Такси и автобус не запишутся, а уведомления о камерах вне машины не придут.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    PrimaryButton(title: "Включить") { env.answerCarOnlyOffer(accept: true) }
                    SecondaryButton(title: "Не сейчас") { env.answerCarOnlyOffer(accept: false) }
                }
                .padding(.vertical, 6)
            }
        }
    }
}

/// «Моя машина»: CarPlay — всегда своя; Bluetooth — выбранный здесь.
struct CarLinkDevicesSection: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env.settings
        let chosen = settings.carDevices
        let connected = CarLink.candidates(env.carLink.ports)
            .filter { port in port.kind == .bluetooth && !CarLink.matches(port, chosen) }
        Section {
            LabeledContent {
                Text("всегда")
            } label: {
                row(Text(verbatim: "CarPlay"), symbol: "car.fill")
            }
            ForEach(chosen) { device in
                LabeledContent {
                    Button(role: .destructive) {
                        settings.carDevices.removeAll { $0.uid == device.uid }
                        env.carLink.chosenChanged()
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .tapTarget()
                    .accessibilityLabel(Text("Убрать"))
                } label: {
                    row(Text(verbatim: device.name), symbol: "car.side.fill")
                }
            }
            ForEach(connected, id: \.uid) { port in
                Button {
                    settings.carDevices.append(CarAudioDevice(uid: port.uid, name: port.name))
                    env.carLink.chosenChanged()
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            row(Text(verbatim: port.name),
                                symbol: CarLink.looksLikeHeadphones(port.name)
                                    ? "headphones" : "dot.radiowaves.left.and.right")
                                .foregroundStyle(Theme.textPrimary)
                            if CarLink.looksLikeHeadphones(port.name) {
                                Text("Похоже на наушники — с ними поездка начнётся и в такси")
                                    .font(.footnote)
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "plus.circle.fill").foregroundStyle(Theme.accent)
                    }
                }
            }
            if chosen.isEmpty, connected.isEmpty {
                Text("Сядьте в машину, подключите телефон к магнитоле по Bluetooth — она появится здесь.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsExplainer([
                "CarPlay будит приложение сам — поездка начинается сразу при подключении.",
                "Bluetooth приложение не будит: iOS сообщает о магнитоле, только когда приложение уже проснулось. Обычно это первые полкилометра пути — первая камера у дома может прийти уведомлением, а не голосом.",
                "Отключились — поездка закончится через две минуты. Заправка и магазин по пути останутся одной поездкой.",
            ])
        } header: {
            Text("Моя машина")
        } footer: {
            Text("Поездка начинается при подключении к этим устройствам.")
        }
        .onAppear { env.carLink.refresh(reason: "настройки") }
    }

    /// Строка «значок + имя» в одну линию (Label внутри LabeledContent
    /// ставил значок над текстом).
    private func row(_ title: Text, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            title
        }
    }
}
