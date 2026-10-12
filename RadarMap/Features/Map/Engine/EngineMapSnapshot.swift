//
//  EngineMapSnapshot.swift
//  RadarMap
//
//  Снимок НАШЕЙ карты для картинок в прокрутке и карточек «Поделиться».
//
//  До 13.10 превью поездки в «Итогах» и карточки «Поделиться» рисовались на
//  снимке карты Apple (MKMapSnapshotter): единственное место в приложении,
//  где была чужая подложка — другие цвета, другие шрифты, и на карточке в
//  соцсети наша поездка выглядела как чужая (план прода, 2.1). Теперь
//  снимок делает движок (MLNMapSnapshotter) по тому же стилю и тем же
//  подписанным тайлам, что и живая карта: сторож тайлов (EngineTileGuard)
//  стоит на уровне URLProtocol и проверяет и эти запросы.
//
//  Стиль снимку нужен файлом (URL), а не строкой — пишем JSON во временный
//  файл раз на тему и выпуск. Нет выпуска тайлов или снимок не вышел
//  (офлайн) — вызывающий рисует на снимке Apple или на пустом фоне, как и
//  раньше: картинка обязана быть всегда.
//

#if canImport(MapLibre)
import CoreLocation
import MapKit
import MapLibre
import os
import UIKit

enum EngineMapSnapshot {

    struct Result {
        let image: UIImage
        let project: @Sendable (CLLocationCoordinate2D) -> CGPoint
    }

    /// Снимок области `rect` размером `size` точек. nil — не вышло.
    @MainActor
    static func render(rect: MKMapRect, size: CGSize, daylight: Bool, scale: CGFloat) async -> Result? {
        guard let styleURL = styleFile(daylight: daylight) else { return nil }
        EngineTileGuard.install()
        let sw = MKMapPoint(x: rect.minX, y: rect.maxY).coordinate
        let ne = MKMapPoint(x: rect.maxX, y: rect.minY).coordinate
        let camera = MLNMapCamera(lookingAtCenter: MKMapPoint(x: rect.midX, y: rect.midY).coordinate,
                                  altitude: 1_000, pitch: 0, heading: 0)
        let options = MLNMapSnapshotOptions(styleURL: styleURL, camera: camera, size: size)
        options.coordinateBounds = MLNCoordinateBounds(sw: sw, ne: ne)
        options.scale = scale
        options.showsLogo = false
        // Подпись «© OpenStreetMap» карточка ставит сама (ShareCardShell).
        options.showsAttribution = false
        let snapshotter = MLNMapSnapshotter(options: options)
        let snapshot: MLNMapSnapshot? = await withCheckedContinuation { continuation in
            snapshotter.start { snapshot, error in
                if let error {
                    Log.app.notice("снимок карты движка не получен: \(error.localizedDescription, privacy: .public)")
                }
                continuation.resume(returning: snapshot)
            }
        }
        guard let snapshot else { return nil }
        return Result(image: snapshot.image, project: { snapshot.point(for: $0) })
    }

    // MARK: - Стиль файлом

    private static let lock = OSAllocatedUnfairLock<[String: URL]>(initialState: [:])

    /// JSON стиля во временном файле — по одному на тему и выпуск тайлов.
    @MainActor
    private static func styleFile(daylight: Bool) -> URL? {
        let base = AppConfig.syncBaseURL
        let release = TileReleaseStore.restoredFromDisk()
        let json: String?
        if let release {
            json = EngineModernStyle.json(daylight: daylight, base: base, release: release,
                                          houses: true, places: false, driving: true)
        } else if EngineTileGuard.isReady {
            json = EngineMapStyle.json(daylight: daylight, base: base, houses: true)
        } else {
            json = nil
        }
        guard let json else { return nil }
        let key = "\(daylight)-\(release?.version ?? 0)-\(json.count)"
        if let cached = lock.withLock({ $0[key] }), FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-snapshot-\(key.hashValue).json")
        do {
            try json.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.app.error("стиль для снимка не записан: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        lock.withLock { $0[key] = url }
        return url
    }
}
#endif
