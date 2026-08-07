//
//  BatteryChip.swift
//  RadarMap
//
//  Заряд телефона на приборке: % и молния на зарядке.
//
//  Телефон в держателе — единственный момент, когда водителю важен заряд
//  ИМЕННО в этом приложении: приборка строилась ради батареи, и её экран —
//  то место, где экономия должна быть видна, а не предполагаться.
//
//  Мониторинг батареи включается ТОЛЬКО пока чип на экране и выключается в
//  onDisappear: держать его постоянно — значит будить процесс уведомлениями
//  системы ради цифры, на которую никто не смотрит.
//

import SwiftUI
import UIKit

struct BatteryChip: View {
    @State private var level: Float = -1
    @State private var isCharging = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isCharging ? "bolt.fill" : symbol)
                .font(.rounded(12, .semibold))
                .foregroundStyle(tint)
            if level >= 0 {
                Text("\(Int((level * 100).rounded())) %")
                    .font(.rounded(13, .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .onAppear {
            UIDevice.current.isBatteryMonitoringEnabled = true
            refresh()
        }
        .onDisappear { UIDevice.current.isBatteryMonitoringEnabled = false }
        .onReceive(NotificationCenter.default.publisher(
            for: UIDevice.batteryLevelDidChangeNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: UIDevice.batteryStateDidChangeNotification)) { _ in refresh() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(level >= 0
            ? Text("Заряд \(Int((level * 100).rounded())) процентов")
            : Text("Заряд неизвестен"))
    }

    private func refresh() {
        level = UIDevice.current.batteryLevel
        let state = UIDevice.current.batteryState
        isCharging = state == .charging || state == .full
    }

    private var symbol: String {
        switch level {
        case ..<0:      return "battery.50percent"   // симулятор: уровень неизвестен
        case ..<0.2:    return "battery.25percent"
        case ..<0.6:    return "battery.50percent"
        case ..<0.85:   return "battery.75percent"
        default:        return "battery.100percent"
        }
    }

    private var tint: Color {
        if isCharging { return Theme.success }
        return level >= 0 && level < 0.2 ? Theme.danger : Theme.textTertiary
    }
}
