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
    @ObservationIgnored private let session: URLSession

    /// Анонимный идентификатор для защиты от спама (свой, не пересекается с другими сервисами).
    @ObservationIgnored private let deviceID: String = {
        let key = "feedbackDeviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config)
    }

    /// Сообщить об ошибке в данных камеры. true — сервер принял.
    func reportCamera(_ camera: Camera, reason: CameraReportReason, dbVersion: Int) async -> Bool {
        let payload: [String: Any] = [
            "camera_id": camera.id,
            "reason": reason.rawValue,
            "lat": camera.lat,
            "lon": camera.lon,
            "db_version": dbVersion,
            "device": deviceID,
        ]
        return await post(path: "api/camera_report", payload: payload)
    }

    /// Сообщение разработчику (форма в настройках). true — сервер принял.
    func sendMessage(_ text: String, contact: String) async -> Bool {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let payload: [String: Any] = [
            "message": String(text.prefix(2000)),
            "contact": String(contact.prefix(200)),
            "app_version": version,
            "device": deviceID,
        ]
        return await post(path: "api/feedback", payload: payload)
    }

    private func post(path: String, payload: [String: Any]) async -> Bool {
        do {
            var request = URLRequest(url: AppConfig.syncBaseURL.appendingPathComponent(path))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }
}
