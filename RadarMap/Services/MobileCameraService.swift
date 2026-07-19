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
                // Частые пары inactive→active (Face ID, шторка, переключатель
                // приложений) перезапускают цикл — интервал держим и между ними,
                // иначе каждый возврат в приложение будил бы радио лишним GET.
                if let self, Date().timeIntervalSince(self.lastRefreshAt) >= AppConfig.mobilePollInterval {
                    await self.refresh()
                }
                await Task.pause(seconds: AppConfig.mobilePollInterval)
            }
        }
    }

    @ObservationIgnored private var lastRefreshAt: Date = .distantPast

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private struct APIReport: Decodable {
        let id: Int
        let lat: Double
        let lon: Double
        let expires: Double
        let type: String?      // старый сервер поля не шлёт — трактуем как радар
        let up: Int?
        let created: Double?
    }
    private struct MobileResponse: Decodable { let reports: [APIReport] }

    /// Подтверждения по отметке (для бейджа доверия в карточке).
    struct Confirmation {
        let upvotes: Int
        let created: Date
    }
    @ObservationIgnored private var confirmations: [Int: Confirmation] = [:]

    func confirmation(for cameraID: Int) -> Confirmation? { confirmations[cameraID] }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        lastRefreshAt = Date()   // считаем попытку, не успех — при ошибке сети не долбим сервер
        do {
            let decoded = try await api.get("api/mobile", as: MobileResponse.self)
            var fresh: [Int: Confirmation] = [:]
            reports = decoded.reports.map { report in
                let kind = ReportKind(rawValue: report.type ?? "") ?? .radar
                let id = Self.idOffset + report.id
                fresh[id] = Confirmation(upvotes: report.up ?? 0,
                                         created: Date(timeIntervalSince1970: report.created ?? 0))
                return Camera(
                    id: id,
                    region: kind.cameraType.displayName,
                    city: "",
                    location: String(format: String(localized: "Отмечен водителями, исчезнет ~%@"),
                                     Self.expiryText(report.expires)),
                    lat: report.lat,
                    lon: report.lon,
                    type: kind.cameraType.sourceString,
                    violations: Camera.defaultViolations(forType: kind.cameraType.sourceString),
                    needsReview: nil
                )
            }
            confirmations = fresh
            store?.setMobileCameras(reports)
        } catch {
            // сети нет — молча живём на последнем известном списке
        }
    }

    // MARK: - Отметка и голосование

    func report(at coordinate: CLLocationCoordinate2D,
                kind: ReportKind = .radar) async -> ReportResult {
        struct Response: Decodable { let id: Int; let merged: Bool }
        do {
            let payload = ["lat": coordinate.latitude, "lon": coordinate.longitude,
                           "device": deviceID, "type": kind.rawValue] as [String: Any]
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

/// Тип отметки водителя: у каждого свой вид на карте и время жизни на сервере
/// (радар/тренога — часы, пост стоит дольше, ДТП рассасывается за час).
enum ReportKind: String, CaseIterable, Identifiable {
    case radar, tripod, post, accident
    var id: String { rawValue }

    var cameraType: CameraType {
        switch self {
        case .radar:    return .mobileRadar
        case .tripod:   return .tripod
        case .post:     return .dpsPost
        case .accident: return .accident
        }
    }
    var title: String { cameraType.displayName }
    var symbol: String { cameraType.symbolName }
}
