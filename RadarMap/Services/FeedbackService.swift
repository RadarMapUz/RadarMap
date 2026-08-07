//
//  FeedbackService.swift
//  RadarMap
//
//  Обратная связь: репорты о камерах («на месте», «больше нет», «неверное место»)
//  и сообщения разработчику. База живёт, пока её поддерживают пользователи —
//  репорты уходят на сервер и разбираются вручную перед правкой базы.
//
//  Офлайн-очередь: в дороге связь ненадёжна, а мнение водителя ценно именно
//  в момент проезда. Не дошло до сервера — сохраняем локально и досылаем при
//  следующем запуске/успешной отправке. Пользователь своё дело сделал — «Спасибо».
//
//  Анонимность: случайный UUID устройства, никакой привязки к личности.
//

import Foundation
import Observation

/// Причина репорта — строки совпадают с серверным API.
enum CameraReportReason: String {
    case gone = "gone"                    // камеры больше нет
    case wrongLocation = "wrong_location" // стоит не там
    case stillHere = "still_here"         // подтверждение: камера на месте (гасит ложные gone)
}

/// Итог отправки: дошло сразу или легло в очередь до связи.
enum FeedbackOutcome { case sent, queued }

@MainActor
@Observable
final class FeedbackService {
    @ObservationIgnored private let api = APIClient()

    /// Анонимный идентификатор для защиты от спама (свой, не пересекается с другими сервисами).
    @ObservationIgnored private let deviceID = Storage.anonymousID(.feedbackDeviceID)

    // MARK: - Очередь недоставленного

    private struct PendingItem: Codable {
        let endpoint: String
        let body: Data          // готовый JSON — досылаем как есть
        let queuedAt: Date
    }

    @ObservationIgnored private var pending: [PendingItem]
    @ObservationIgnored private var isFlushing = false
    private static let queueCap = 100      // защита от бесконечного роста

    private static var queueURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pending_feedback.json")
    }

    init() {
        pending = JSONFile.load([PendingItem].self, from: Self.queueURL, log: Log.network) ?? []
    }

    /// Дослать накопленное (вызывается на старте и после удачной отправки).
    /// Останавливаемся на первом фейле — сервер недоступен, не долбим зря.
    func flushPending() async {
        guard !isFlushing, !pending.isEmpty else { return }
        isFlushing = true
        defer { isFlushing = false }
        while let item = pending.first {
            guard await api.postAccepted(item.endpoint, body: item.body) else { return }
            pending.removeFirst()
            saveQueue()
        }
    }

    private func enqueue(endpoint: String, json: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: json) else { return }
        pending.append(PendingItem(endpoint: endpoint, body: body, queuedAt: Date()))
        if pending.count > Self.queueCap { pending.removeFirst(pending.count - Self.queueCap) }
        saveQueue()
    }

    private func saveQueue() {
        JSONFile.save(pending, to: Self.queueURL, log: Log.network)
    }

    /// Отправить сейчас; не вышло — в очередь. Возвращает, как именно ушло.
    private func deliver(endpoint: String, json: [String: Any]) async -> FeedbackOutcome {
        if await api.postAccepted(endpoint, json: json) {
            await flushPending()   // сервер жив — заодно досылаем старое
            return .sent
        }
        enqueue(endpoint: endpoint, json: json)
        return .queued
    }

    // MARK: - Публичное API

    /// Сообщить о состоянии камеры («на месте» / «нет» / «не там»).
    func reportCamera(_ camera: Camera, reason: CameraReportReason,
                      dbVersion: Int) async -> FeedbackOutcome {
        await deliver(endpoint: "api/camera_report", json: [
            "camera_id": camera.id,
            "reason": reason.rawValue,
            "lat": camera.lat,
            "lon": camera.lon,
            "db_version": dbVersion,
            "device": deviceID,
        ])
    }

    /// «Камера была, а приложение промолчало».
    ///
    /// Самый ценный сигнал, который у нас есть, и до сих пор его негде было
    /// подать: молчание камеры мы ловили только глазами на симуляции, а
    /// водитель в TestFlight мог лишь написать «иногда не предупреждает» —
    /// без места, скорости и маршрута такая жалоба недиагностируема.
    ///
    /// Контекст собирается сам и уходит текстом в общую очередь отзывов
    /// (в админке она уже разбирается по статусам). Отдельного `reason` на
    /// сервере не заводим: разбирать это всё равно человеку, а лишняя
    /// колонка в схеме — миграция ради одной строки.
    func reportMissedAlert(pass: PassedCamera, dbVersion: Int) async -> FeedbackOutcome {
        var lines = ["[не предупредила] камера #\(pass.cameraID)"]
        if !pass.location.isEmpty { lines.append("место: \(pass.location)") }
        lines.append("тип: \(pass.typeRaw)")
        lines.append("скорость в зоне: \(Int(pass.speedKmh)) км/ч")
        if let limit = pass.limitKmh { lines.append("лимит: \(limit) км/ч") }
        if let lat = pass.lat, let lon = pass.lon {
            // Координата ПРОЕЗДА, а не трека: она нужна, чтобы повторить
            // геометрию гейтов, и это единственная точка, без которой жалоба
            // не воспроизводится.
            lines.append("координата: \(String(format: "%.5f, %.5f", lat, lon))")
        }
        // Был ли построен маршрут, запись проезда не хранит — а гейт «камера
        // на маршруте» работает именно от него. Спросим у человека в ответе,
        // но не подставим сюда догадку.
        lines.append("время: \(pass.date.formatted(.iso8601))")
        lines.append("база: v\(dbVersion)")
        return await sendMessage(lines.joined(separator: "\n"), contact: "")
    }

    /// Сообщение разработчику (форма в настройках).
    func sendMessage(_ text: String, contact: String) async -> FeedbackOutcome {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return await deliver(endpoint: "api/feedback", json: [
            "message": String(text.prefix(2000)),
            "contact": String(contact.prefix(200)),
            "app_version": version,
            "device": deviceID,
        ])
    }
}
