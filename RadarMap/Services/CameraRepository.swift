//
//  CameraRepository.swift
//  RadarMap
//
//  Источник данных о камерах: база из cameras.json + свои (локально) − скрытые.
//  Свои камеры и скрытые id сохраняются в Documents/user_cameras.json.
//

import Foundation
import CoreLocation
import MapKit
import Observation

protocol CameraRepository {
    var cameras: [Camera] { get }
    func nearest(to coordinate: CLLocationCoordinate2D, limit: Int) -> [Camera]
    func cameras(in region: MKCoordinateRegion, limit: Int) -> [Camera]
}

@MainActor
@Observable
final class CameraStore: CameraRepository {
    private var bundled: [Camera] = []
    private(set) var loadError: String?

    private(set) var custom: [Camera] = []
    private(set) var hiddenIDs: Set<Int> = []
    /// Передвижные радары с сервера (краудсорсинг), живут несколько часов.
    private(set) var mobile: [Camera] = []

    /// Растёт при любом изменении данных (загрузка/добавление/скрытие) — UI подписывается на это.
    private(set) var revision = 0

    /// Кэш объединённого списка: пересобирается только при изменении данных,
    /// а не при каждом обращении (горячий путь: retile, ближайшие, вход в зону).
    @ObservationIgnored private var mergedCache: [Camera]?
    /// Пространственный индекс: ячейка 0.05° (~5.5 км) → индексы камер в merged-списке.
    /// Запросы «в области» и «ближайшие» не сканируют все 3341 камеры, а берут пару ячеек.
    @ObservationIgnored private var gridCache: [Int: [Int]]?

    /// Итоговый набор для карты и оповещений: база + свои + передвижные, без скрытых.
    var cameras: [Camera] {
        if let mergedCache { return mergedCache }
        let merged = (bundled + custom + mobile).filter { !hiddenIDs.contains($0.id) }
        mergedCache = merged
        return merged
    }

    // MARK: - Пространственный индекс

    private static let gridCellDegrees = 0.05

    nonisolated private static func cellKey(latCell: Int, lonCell: Int) -> Int {
        latCell * 8000 + lonCell
    }
    nonisolated private static func cellOf(lat: Double, lon: Double) -> (Int, Int) {
        (Int((lat + 90) / gridCellDegrees), Int((lon + 180) / gridCellDegrees))
    }

    private func grid() -> [Int: [Int]] {
        if let gridCache { return gridCache }
        var built: [Int: [Int]] = [:]
        built.reserveCapacity(cameras.count / 2)
        for (index, camera) in cameras.enumerated() {
            let (latCell, lonCell) = Self.cellOf(lat: camera.lat, lon: camera.lon)
            built[Self.cellKey(latCell: latCell, lonCell: lonCell), default: []].append(index)
        }
        gridCache = built
        return built
    }

    /// Обновить список передвижных радаров (вызывается MobileCameraService).
    func setMobileCameras(_ cameras: [Camera]) {
        guard cameras != mobile else { return }
        mobile = cameras
        dataChanged()
    }

    private static let firstCustomID = 1_000_001
    private static let dbVersionKey = "cameraDBVersion"

    /// Версия активной базы (встроенная = bundledDBVersion; после OTA — версия с сервера).
    private(set) var dbVersion: Int =
        (UserDefaults.standard.object(forKey: dbVersionKey) as? Int) ?? AppConfig.bundledDBVersion

    init() {
        loadUserData()
        // Декодируем JSON вне главного потока — не блокируем первый кадр.
        Task { [weak self] in
            let result = await Self.decodeDatabase()
            guard let self else { return }
            self.bundled = result.cameras
            self.loadError = result.error
            if !result.usedRemote && self.dbVersion != AppConfig.bundledDBVersion {
                // Скачанная копия испорчена/удалена — честно откатываемся на встроенную версию.
                self.dbVersion = AppConfig.bundledDBVersion
                UserDefaults.standard.removeObject(forKey: Self.dbVersionKey)
            }
            self.dataChanged()
        }
    }

    /// Файл базы, скачанной с сервера (переживает обновления приложения).
    nonisolated private static var remoteFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cameras_remote.json")
    }

    nonisolated private static func decodeDatabase() async -> (cameras: [Camera], error: String?, usedRemote: Bool) {
        // 1) скачанная с сервера копия (если валидна)
        if let data = try? Data(contentsOf: remoteFileURL),
           let decoded = try? JSONDecoder().decode([Camera].self, from: data),
           decoded.count >= 100 {
            return (decoded, nil, true)
        }
        // 2) встроенная база
        guard let url = Bundle.main.url(forResource: "cameras", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Camera].self, from: data) else {
            return ([], "Не удалось загрузить cameras.json из бандла.", false)
        }
        return (decoded, nil, false)
    }

    /// Применить скачанное обновление базы: валидация → атомарная запись → подмена в памяти.
    func applyRemote(data: Data, version: Int) async throws -> Int {
        let decoded = try await Task.detached(priority: .userInitiated) {
            try JSONDecoder().decode([Camera].self, from: data)
        }.value
        guard decoded.count >= 100 else {
            throw NSError(domain: "RadarMap.Sync", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Файл базы неполный (\(decoded.count) камер)."])
        }
        try data.write(to: Self.remoteFileURL, options: .atomic)
        bundled = decoded
        dbVersion = version
        UserDefaults.standard.set(version, forKey: Self.dbVersionKey)
        dataChanged()
        return decoded.count
    }

    private func dataChanged() {
        mergedCache = nil
        gridCache = nil
        revision += 1
    }

    // MARK: - Запросы

    /// Ближайшие камеры: расширяющиеся кольца ячеек индекса вместо сортировки всех 3341
    /// (и без аллокаций CLLocation — критично для ретайлинга на каждом км пути).
    func nearest(to coordinate: CLLocationCoordinate2D, limit: Int) -> [Camera] {
        let all = cameras
        guard !all.isEmpty else { return [] }
        let index = grid()
        let (centerLat, centerLon) = Self.cellOf(lat: coordinate.latitude, lon: coordinate.longitude)

        var candidates: [Int] = []
        var ring = 0
        let maxRing = 60   // 60 × 0.05° ≈ 330 км — дальше камер точно нет смысла искать
        while ring <= maxRing {
            // Ячейки на чебышёвском расстоянии == ring (рамка кольца).
            for latCell in (centerLat - ring)...(centerLat + ring) {
                for lonCell in (centerLon - ring)...(centerLon + ring)
                where max(abs(latCell - centerLat), abs(lonCell - centerLon)) == ring {
                    if let found = index[Self.cellKey(latCell: latCell, lonCell: lonCell)] {
                        candidates.append(contentsOf: found)
                    }
                }
            }
            // Набрали достаточно — добираем ещё одно кольцо (камера у границы ячейки
            // может быть ближе, чем найденные) и выходим.
            if candidates.count >= limit {
                ring += 1
                for latCell in (centerLat - ring)...(centerLat + ring) {
                    for lonCell in (centerLon - ring)...(centerLon + ring)
                    where max(abs(latCell - centerLat), abs(lonCell - centerLon)) == ring {
                        if let found = index[Self.cellKey(latCell: latCell, lonCell: lonCell)] {
                            candidates.append(contentsOf: found)
                        }
                    }
                }
                break
            }
            ring += 1
        }

        return candidates
            .map { (all[$0], GeoMath.fastDistance(coordinate.latitude, coordinate.longitude,
                                                  all[$0].lat, all[$0].lon)) }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    func cameras(in region: MKCoordinateRegion, limit: Int) -> [Camera] {
        let latMin = region.center.latitude  - region.span.latitudeDelta  / 2
        let latMax = region.center.latitude  + region.span.latitudeDelta  / 2
        let lonMin = region.center.longitude - region.span.longitudeDelta / 2
        let lonMax = region.center.longitude + region.span.longitudeDelta / 2

        // Область → ячейки индекса; при гигантской области (десятки тысяч ячеек)
        // дешевле пройтись по списку целиком.
        let all = cameras
        let (loLat, loLon) = Self.cellOf(lat: latMin, lon: lonMin)
        let (hiLat, hiLon) = Self.cellOf(lat: latMax, lon: lonMax)
        let cellCount = (hiLat - loLat + 1) * (hiLon - loLon + 1)

        var visible: [Camera] = []
        if cellCount <= 6000 {
            let index = grid()
            for latCell in loLat...hiLat {
                for lonCell in loLon...hiLon {
                    guard let found = index[Self.cellKey(latCell: latCell, lonCell: lonCell)] else { continue }
                    for i in found {
                        let camera = all[i]
                        if camera.lat >= latMin, camera.lat <= latMax,
                           camera.lon >= lonMin, camera.lon <= lonMax {
                            visible.append(camera)
                        }
                    }
                }
            }
        } else {
            visible = all.filter {
                $0.lat >= latMin && $0.lat <= latMax && $0.lon >= lonMin && $0.lon <= lonMax
            }
        }

        guard visible.count > limit else { return visible }
        return visible
            .map { ($0, GeoMath.fastDistance(region.center.latitude, region.center.longitude,
                                             $0.lat, $0.lon)) }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    // MARK: - Свои камеры

    @discardableResult
    func addCamera(at coordinate: CLLocationCoordinate2D, type: CameraType, label: String) -> Camera {
        let id = (custom.map(\.id).max() ?? (Self.firstCustomID - 1)) + 1
        let violations: [String] = type == .stationaryRadar
            ? ["тезликни ошириш"]
            : ["тезликни ошириш", "қизил чироқда ўтиш"]
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let camera = Camera(
            id: id,
            region: String(localized: "Моя камера"),
            city: "",
            location: name.isEmpty ? String(localized: "Добавлено вручную") : name,
            lat: coordinate.latitude,
            lon: coordinate.longitude,
            type: type.sourceString,
            violations: violations,
            needsReview: nil
        )
        custom.append(camera)
        dataChanged()
        persist()
        return camera
    }

    func deleteCustom(_ camera: Camera) {
        custom.removeAll { $0.id == camera.id }
        dataChanged()
        persist()
    }

    func isCustom(_ camera: Camera) -> Bool { camera.id >= Self.firstCustomID }

    // MARK: - Скрытие / жалоба

    func hide(_ camera: Camera) {
        hiddenIDs.insert(camera.id)
        dataChanged()
        persist()
    }

    func unhide(id: Int) {
        hiddenIDs.remove(id)
        dataChanged()
        persist()
    }

    // MARK: - Хранение

    private struct UserData: Codable {
        var custom: [Camera]
        var hidden: [Int]
    }

    private var storeURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("user_cameras.json")
    }

    private func loadUserData() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode(UserData.self, from: data) else { return }
        custom = decoded.custom
        hiddenIDs = Set(decoded.hidden)
    }

    private func persist() {
        let payload = UserData(custom: custom, hidden: Array(hiddenIDs))
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
