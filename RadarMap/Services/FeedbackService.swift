//
//  FeedbackService.swift
//  RadarMap
//
//  Обратная связь: репорты о камерах («больше нет», «неверное место») и
//  сообщения разработчику. База живёт, пока её поддерживают пользователи —
//  репорты уходят на сервер и разбираются вручную перед правкой базы.
//  Анонимность: случайный UUID устройства, никакой привязки к личности.
//

import Foundation
import Observation

/// Причина репорта — строки совпадают с серверным API.
enum CameraReportReason: String {
    case gone = "gone"                    // камеры больше нет
    case wrongLocation = "wrong_location" // стоит не там
}

@MainActor
@Observable
final class FeedbackService {
    @ObservationIgnored private let api = APIClient()

    /// Анонимный идентификатор для защиты от спама (свой, не пересекается с другими сервисами).
    @ObservationIgnored private let deviceID = Storage.anonymousID(.feedbackDeviceID)

    /// Сообщить об ошибке в данных камеры. true — сервер принял.
    func reportCamera(_ camera: Camera, reason: CameraReportReason, dbVersion: Int) async -> Bool {
        await api.postAccepted("api/camera_report", json: [
            "camera_id": camera.id,
            "reason": reason.rawValue,
            "lat": camera.lat,
            "lon": camera.lon,
            "db_version": dbVersion,
            "device": deviceID,
        ])
    }

    /// Сообщение разработчику (форма в настройках). true — сервер принял.
    func sendMessage(_ text: String, contact: String) async -> Bool {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return await api.postAccepted("api/feedback", json: [
            "message": String(text.prefix(2000)),
            "contact": String(contact.prefix(200)),
            "app_version": version,
            "device": deviceID,
        ])
    }
}
