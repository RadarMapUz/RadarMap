//
//  RadarControls.swift
//  RadarMapWidgets
//
//  Кнопки Пункта управления и кнопки действия (iOS 18). «Поездка» и «Звук» —
//  переключатели: значение читается из App Group, приложение обновляет его
//  при каждой смене (ControlBridge). «Домой» и «На работу» открывают тот же
//  экран «Поехали», что и виджет «Дорога».
//

import AppIntents
import SwiftUI
import WidgetKit

struct TripValueProvider: ControlValueProvider {
    var previewValue: Bool { false }
    func currentValue() async throws -> Bool { ControlBridge.tripActive }
}

struct SoundValueProvider: ControlValueProvider {
    var previewValue: Bool { true }
    func currentValue() async throws -> Bool { !ControlBridge.muted }
}

/// `kind` прежний: кнопка «Начать поездку» уже стоит у людей в Пункте управления.
struct StartTripControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ControlBridge.tripKind, provider: TripValueProvider()) { isOn in
            ControlWidgetToggle("Поездка", isOn: isOn, action: ControlTripIntent()) { on in
                Label(on ? "Идёт" : "Начать", systemImage: "car.fill")
            }
            .tint(SW.action)
        }
        .displayName("Поездка")
        .description("Поездка с предупреждениями о камерах — одним нажатием")
    }
}

struct RadarReportControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "uz.radarmap.ios.radar") {
            ControlWidgetButton(action: ControlRadarIntent()) {
                Label("Радар!", systemImage: "exclamationmark.triangle.fill")
            }
            .tint(SW.action)
        }
        .displayName("Радар!")
        .description("Отметить радар в текущей точке. Работает в поездке")
    }
}

struct SoundControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ControlBridge.soundKind, provider: SoundValueProvider()) { isOn in
            ControlWidgetToggle("Звук", isOn: isOn, action: ControlSoundIntent()) { on in
                Label(on ? "Включён" : "Выключен",
                      systemImage: on ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }
        }
        .displayName("Звук")
        .description("Сигналы и голос о камерах")
    }
}

struct GoHomeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "uz.radarmap.ios.go-home") {
            ControlWidgetButton(action: OpenURLIntent(TripLink.ownGoURL(.home))) {
                Label("Домой", systemImage: "house.fill")
            }
        }
        .displayName("Домой")
        .description("Маршрут домой и экран «Поехали»")
    }
}

struct GoWorkControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "uz.radarmap.ios.go-work") {
            ControlWidgetButton(action: OpenURLIntent(TripLink.ownGoURL(.work))) {
                Label("На работу", systemImage: "briefcase.fill")
            }
        }
        .displayName("На работу")
        .description("Маршрут на работу и экран «Поехали»")
    }
}
