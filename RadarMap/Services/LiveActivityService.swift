//
//  LiveActivityService.swift
//  RadarMap
//
//  Live Activity «поездка»: ближайшая камера на локскрине и в Dynamic Island.
//  Стартует в foreground при начале движения (ограничение iOS: запуск возможен
//  только на переднем плане), живёт при сворачивании/блокировке, обновляется на
//  фоновых пробуждениях, завершается при возвращении в приложение.
//

import Foundation
import ActivityKit

@MainActor
final class LiveActivityService {
    private var activity: Activity<CameraActivityAttributes>?
    private var lastSentState: CameraActivityAttributes.ContentState?

    var isActive: Bool { activity != nil }

    func startIfNeeded(state: CameraActivityAttributes.ContentState) {
        guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let quantized = Self.quantize(state)
        activity = try? Activity.request(
            attributes: CameraActivityAttributes(),
            content: .init(state: quantized, staleDate: nil)
        )
        lastSentState = quantized
    }

    func update(state: CameraActivityAttributes.ContentState) {
        guard let activity else { return }
        // Квантуем расстояние до 25 м и не шлём одинаковые состояния —
        // у Live Activity ограниченный бюджет обновлений.
        let quantized = Self.quantize(state)
        guard quantized != lastSentState else { return }
        lastSentState = quantized
        Task { await activity.update(.init(state: quantized, staleDate: nil)) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        lastSentState = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private static func quantize(_ state: CameraActivityAttributes.ContentState) -> CameraActivityAttributes.ContentState {
        var s = state
        if let d = s.distanceMeters {
            s.distanceMeters = (d / 25).rounded() * 25
        }
        return s
    }
}
