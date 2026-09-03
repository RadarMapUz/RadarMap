//
//  CameraClusterIDTests.swift
//  RadarMapTests
//
//  Ключ кластеризации маркера камеры на карте машины.
//
//  Тест существует из-за падения, а не для полноты: цель исключалась из
//  кластеров через `clusteringIdentifier = nil`, и nil на живом маркере ломал
//  кластеризацию MapKit — `_existingClusterViewsForClusterID:` клал nil ключом
//  в словарь, «key cannot be nil», SIGABRT. Четырнадцать падений с 28 августа
//  по 3 сентября, все с одной подписью, все на CarPlay.
//
//  Поэтому проверяется ровно то, на чём приложение падало, и то, что легко
//  сломать, починив первое: цель обязана остаться вне групп, а обычные
//  маркеры — по-прежнему слипаться в счётчик.
//

import XCTest
@testable import RadarMap

final class CameraClusterIDTests: XCTestCase {

    /// Главное свойство: ключ есть ВСЕГДА. Тип уже не даёт вернуть nil — тест
    /// сторожит непустоту и то, что подпись не переписали обратно на `String?`.
    func testClusterIDIsNeverEmpty() {
        for id in [0, 1, 3511, Int.max, -1] {
            for isTarget in [true, false] {
                let key = CameraMarkerView.clusterID(isTarget: isTarget, cameraID: id)
                XCTAssertFalse(key.isEmpty,
                               "пустой ключ у камеры \(id), цель=\(isTarget)")
            }
        }
    }

    /// Цель не слипается ни с соседями, ни с другой целью: группа собирается
    /// из двух и более маркеров с ОДИНАКОВЫМ ключом, а у цели он свой на камеру.
    func testTargetGetsItsOwnGroup() {
        let target = CameraMarkerView.clusterID(isTarget: true, cameraID: 100)
        let otherTarget = CameraMarkerView.clusterID(isTarget: true, cameraID: 101)
        let plain = CameraMarkerView.clusterID(isTarget: false, cameraID: 100)

        XCTAssertNotEqual(target, plain)
        XCTAssertNotEqual(target, otherTarget)
    }

    /// Обратная сторона той же монеты: обычные маркеры обязаны делить один
    /// ключ. Дай каждому свой — и счётчик групп исчезнет, а карта в городе
    /// снова превратится в сыпь перекрывающихся значков.
    func testPlainMarkersShareOneGroup() {
        let first = CameraMarkerView.clusterID(isTarget: false, cameraID: 1)
        let second = CameraMarkerView.clusterID(isTarget: false, cameraID: 2)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first, CameraMarkerView.baseClusterID)
    }

    /// Ключ цели постоянен: `applyTarget` приходит каждый тик, и ключ, меняющийся
    /// от вызова к вызову, заставлял бы MapKit пересобирать группы на ровном
    /// месте — ровно та работа, внутри которой приложение и падало.
    func testTargetIDIsStableAcrossCalls() {
        let first = CameraMarkerView.clusterID(isTarget: true, cameraID: 777)
        let second = CameraMarkerView.clusterID(isTarget: true, cameraID: 777)

        XCTAssertEqual(first, second)
    }
}
