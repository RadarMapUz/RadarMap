//
//  MobileCameraService.swift
//  RadarMap
//
//  Краудсорсинг передвижных радаров: пользователи отмечают радар на карте,
//  сервер объединяет отметки (TTL ~3 ч, продление подтверждениями, скрытие
//  дизлайками), приложение опрашивает список каждые 3 минуты на переднем плане.
//  Анонимность: случайный UUID устройства, никакой привязки к личности.
//

import Foundation
import CoreLocation
import Observation

@MainActor
@Observable
final class MobileCameraService {
    enum ReportResult { case created, confirmed, failed }

    private(set) var reports: [Camera] = []
    private(set) var isRefreshing = false

    @ObservationIgnored private weak var store: CameraStore?
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    /// Анонимный идентификатор устройства для защиты от спама.
    @ObservationIgnored private let deviceID: String = {
        let key = "mobileDeviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()

    /// Смещение id, чтобы передвижные не пересекались с базой (1…) и своими (1 000 001…).
    static let idOffset = 2_000_000

    init(store: CameraStore) {
        self.store = store
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config)
    }

    // MARK: - Опрос

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(AppConfig.mobilePollInterval))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private struct APIReport: Decodable {
        let id: Int
        let lat: Double
        let lon: Double
        let expires: Double
    }
    private struct MobileResponse: Decodable { let reports: [APIReport] }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let url = AppConfig.syncBaseURL.appendingPathComponent("api/mobile")
            let (data, _) = try await session.data(from: url)
            let decoded = try JSONDecoder().decode(MobileResponse.self, from: data)
            reports = decoded.reports.map { api in
                Camera(
                    id: Self.idOffset + api.id,
                    region: String(localized: "Передвижной радар"),
                    city: "",
                    location: String(format: String(localized: "Отмечен водителями, исчезнет ~%@"),
                                     Self.expiryText(api.expires)),
                    lat: api.lat,
                    lon: api.lon,
                    type: CameraType.mobileRadar.sourceString,
                    violations: Camera.radarViolations,
                    needsReview: nil
                )
            }
            store?.setMobileCameras(reports)
        } catch {
            // сети нет — молча живём на последнем известном списке
        }
    }

    // MARK: - Отметка и голосование

    func report(at coordinate: CLLocationCoordinate2D) async -> ReportResult {
        struct Response: Decodable { let id: Int; let merged: Bool }
        do {
            let payload = ["lat": coordinate.latitude, "lon": coordinate.longitude,
                           "device": deviceID] as [String: Any]
            let response: Response = try await post(path: "api/report", payload: payload)
            await refresh()
            return response.merged ? .confirmed : .created
        } catch {
            return .failed
        }
    }

    /// value: true = «радар на месте» (продлевает жизнь), false = «радара нет».
    func vote(cameraID: Int, stillThere: Bool) async {
        struct Response: Decodable { let ok: Bool }
        let payload = ["id": cameraID - Self.idOffset, "device": deviceID,
                       "value": stillThere ? 1 : -1] as [String: Any]
        let _: Response? = try? await post(path: "api/vote", payload: payload)
        await refresh()
    }

    func isMobile(_ camera: Camera) -> Bool { camera.id >= Self.idOffset }

    // MARK: - Внутреннее

    private func post<R: Decodable>(path: String, payload: [String: Any]) async throws -> R {
        var request = URLRequest(url: AppConfig.syncBaseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(R.self, from: data)
    }

    private static func expiryText(_ expires: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: expires)
        return date.formatted(date: .omitted, time: .shortened)
    }
}
