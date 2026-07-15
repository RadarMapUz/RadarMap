//
//  CameraStoreTests.swift
//  RadarMapTests
//
//  Пространственный индекс хранилища: «ближайшие» и «в области».
//  Свои камеры ставим в океан (лат. 20°), чтобы не пересекаться со встроенной базой.
//

import XCTest
import MapKit
import CoreLocation
@testable import RadarMap

final class CameraStoreTests: XCTestCase {

    /// Один экземпляр на весь прогон: деаллокация MainActor-класса в конце теста
    /// крашит swift-рантайм (в приложении store живёт вечно — продакшена не касается).
    private static let sharedStore = CameraStore()

    /// Свои камеры и скрытия персистятся в Documents/UserDefaults — вычищаем
    /// артефакты прошлых тестов, иначе они загрязняют друг друга.
    private func freshStore() -> CameraStore {
        let store = Self.sharedStore
        for camera in store.custom { store.deleteCustom(camera) }
        // ID своих камер переиспользуются — скрытия прошлых прогонов задели бы новые камеры.
        for id in store.hiddenIDs { store.unhide(id: id) }
        return store
    }

    func testNearestOrdersByDistanceViaGridRings() {
        let store = freshStore()
        let origin = CLLocationCoordinate2D(latitude: 20.0, longitude: 60.0)

        store.addCamera(at: .init(latitude: 20.030, longitude: 60.0), type: .stationaryRadar, label: "далёкая")   // ~3.3 км
        store.addCamera(at: .init(latitude: 20.002, longitude: 60.0), type: .stationaryCamera, label: "ближняя")  // ~220 м
        store.addCamera(at: .init(latitude: 20.010, longitude: 60.0), type: .stationaryCamera, label: "средняя")  // ~1.1 км

        let nearest = store.nearest(to: origin, limit: 3)
        XCTAssertEqual(nearest.map(\.location), ["ближняя", "средняя", "далёкая"])
    }

    func testCamerasInRegionRespectsBounds() {
        let store = freshStore()
        store.addCamera(at: .init(latitude: 20.0, longitude: 60.0), type: .stationaryCamera, label: "внутри")
        store.addCamera(at: .init(latitude: 20.5, longitude: 60.0), type: .stationaryCamera, label: "снаружи")

        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 20.0, longitude: 60.0),
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1))
        let found = store.cameras(in: region, limit: 10)

        XCTAssertTrue(found.contains { $0.location == "внутри" })
        XCTAssertFalse(found.contains { $0.location == "снаружи" })
    }

    func testHiddenCameraDisappearsFromQueries() {
        let store = freshStore()
        let cam = store.addCamera(at: .init(latitude: 20.0, longitude: 61.0),
                                  type: .stationaryCamera, label: "спрячь меня")
        store.hide(cam)
        let nearest = store.nearest(to: .init(latitude: 20.0, longitude: 61.0), limit: 5)
        XCTAssertFalse(nearest.contains { $0.id == cam.id })
    }
}
