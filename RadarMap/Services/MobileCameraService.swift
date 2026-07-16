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
    @ObservationIgnored private let api = APIClient()
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    /// Анонимный идентификатор устройства для защиты от спама.
    @ObservationIgnored private let deviceID = Storage.anonymousID(.mobileDeviceID)

    /// Смещение id, чтобы передвижные не пересекались с базой (1…) и своими (1 000 001…).
    static let idOffset = 2_000_000

    init(store: CameraStore) {
        self.store = store
    }

    // MARK: - Опрос

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                await Task.pause(seconds: AppConfig.mobilePollInterval)
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
            let decoded = try await api.get("api/mobile", as: MobileResponse.self)
            reports = decoded.reports.map { report in
                Camera(
                    id: Self.idOffset + report.id,
                    region: String(localized: "Передвижной радар"),
                    city: "",
                    location: String(format: String(localized: "Отмечен водителями, исчезнет ~%@"),
                                     Self.expiryText(report.expires)),
                    lat: report.lat,
                    lon: report.lon,
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
            let response = try await api.post("api/report", json: payload, as: Response.self)
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
        // Голос — best-effort: не дошёл — не страшно, сервер дедуплицирует повторы.
        let _: Response? = try? await api.post("api/vote", json: payload, as: Response.self)
        await refresh()
    }

    func isMobile(_ camera: Camera) -> Bool { camera.id >= Self.idOffset }

    // MARK: - Внутреннее

    private static func expiryText(_ expires: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: expires)
        return date.formatted(date: .omitted, time: .shortened)
    }
}
