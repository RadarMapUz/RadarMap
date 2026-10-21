//
//  LocationService+Geofences.swift
//  RadarMap
//
//  Геозоны: 20 ближайших камер (предел iOS), входы и выходы, очередь входов.
//

import Foundation
import AVFAudio
import CoreLocation
import Observation
import os
import UIKit

extension LocationService {

    // MARK: - Пере-тайлинг 20 ближайших

    func retileIfNeeded(around coordinate: CLLocationCoordinate2D) {
        // Пустое окно = данные ещё не загрузились на прошлом тайлинге — пробуем снова.
        guard let anchor, !trackedCameras.isEmpty else { return retile(around: coordinate) }
        // Окно обязано покрывать всё, до чего мы доедем до следующего пересчёта:
        // иначе камера впереди не попадёт в кандидаты и мы о ней промолчим. В
        // плотном городе радиус окна маленький в метрах — там пересчитываем чаще.
        let reach = max(AppConfig.retileMinDistance,
                        min(AppConfig.retileDistance,
                            trackedRadius - AppConfig.trackedCoverageMeters))
        let moved = GeoMath.fastDistance(anchor.latitude, anchor.longitude,
                                         coordinate.latitude, coordinate.longitude)
        if moved < reach { return }
        retile(around: coordinate)
    }

    func retile(around coordinate: CLLocationCoordinate2D) {
        // Якорь ставим здесь, а не только в retileIfNeeded: refreshMonitoring
        // зовёт retile напрямую, и без якоря следующий тик перетайлил бы повторно.
        anchor = coordinate

        // Окно кандидатов на оповещение — широкое; геозоны — только 20 ближайших
        // из него (жёсткий лимит iOS). Раньше это был один список на двоих, и
        // движок алертов видел ровно те 20 камер, что и геозоны.
        let tracked = repository.nearest(to: coordinate, limit: AppConfig.trackedCamerasLimit)
        trackedCameras = tracked
        // fastDistance, а не CLLocation: окно из 150 камер — это 300 объектов на
        // каждый пересчёт, а погрешность приближения тут доли процента.
        func distance(to camera: Camera) -> CLLocationDistance {
            GeoMath.fastDistance(coordinate.latitude, coordinate.longitude,
                                 camera.lat, camera.lon)
        }
        // Радиус окна — до самой дальней камеры в нём (список отсортирован).
        trackedRadius = tracked.last.map(distance(to:)) ?? .greatestFiniteMagnitude
        // Геозоны — без истёкших отметок водителей: слотов всего двадцать.
        let now = Date()
        let nearest = Array(tracked.lazy.filter { !$0.isExpiredMobile(at: now) }
            .prefix(AppConfig.maxMonitoredRegions))
        nearbyCameras = nearest
        alertedCameraIDs.formIntersection(Set(nearest.map(\.id)))
        // Плотность камер вокруг — сигнал «город» для умного режима оповещений.
        // Считаем по всему окну: по двадцатке цифра упиралась в потолок.
        cameraDensity3km = tracked.count { distance(to: $0) <= 3000 }

        // Геозоны — только в ТИХОМ ФОНЕ, где они единственный способ узнать о
        // камере. Пока идёт непрерывный GPS, handleEnter выходит первой
        // строкой, то есть сработать они не могут в принципе, а ретайл каждые
        // 300–1500 м гонит в locationd по сорок синхронных пар
        // stop/startMonitoring — на главном потоке, на ходу.
        //
        // Условие было `!isTripActive`, и это оставляло открытым самый частый
        // сценарий машины: CarPlay подключён, поездку водитель ещё не начал.
        // Непрерывный GPS там уже идёт (applyLocationMode держит его по
        // isCarPlayConnected), фиксы приходят раз в секунду на скорости — и
        // каждые несколько сотен метров главный поток уходил в locationd за
        // невозможным событием. Экран машины при этом продолжает показывать
        // последний кадр: он нарисован, но не живой.
        //
        // Возвращает геозоны applyLocationMode при уходе в тихий фон.
        // База камер ещё читается (процесс подняли в фоне): с пустой базой
        // план «ноль геозон» снял бы все двадцать, и вход, который iOS ещё не
        // доставила, пропал бы. Первую настоящую расстановку сделает загрузка
        // базы (refreshMonitoring по ревизии) — ревью S3, 20.10.
        guard repository.isDatabaseLoaded else {
            geofencesArmed = false
            return
        }
        guard !isTripActive, !isForeground else {
            // Пока идёт непрерывный GPS, геозоны заведомо устаревают: машина
            // уезжает, а они остаются вокруг точки, где экран открыли. Помним
            // это, чтобы уход в тихий фон их пересобрал ровно один раз.
            geofencesArmed = false
            geofencePlan.disarm()
            return
        }
        geofencesArmed = true
        // Наблюдатель ревизии базы (AppEnvironment) зовёт refreshMonitoring на каждое изменение
        // списка, а изменением считается и чужая отметка за пять километров —
        // в двадцатку ближайших она не попадает, и переставлять из-за неё
        // сорок геозон значит платить за краудсорс батареей стоящего телефона.
        guard geofencePlan.needsRearm(cameras: nearest, radius: settings.alertRadius) else { return }
        geofencePlan.arm(cameras: nearest, radius: settings.alertRadius)
        // Сорок синхронных походов в locationd — самый дорогой участок главного
        // потока во всём приложении. Под меткой: если сторож поймает фриз здесь,
        // спорить будет не о чем.
        MainWork.during(MainWork.Name.geofences) {
            manager.monitoredRegions.forEach { manager.stopMonitoring(for: $0) }
            for camera in nearest {
                let region = CLCircularRegion(
                    center: camera.coordinate,
                    radius: settings.alertRadius,
                    identifier: Self.regionID(for: camera.id)
                )
                region.notifyOnEntry = true
                region.notifyOnExit = true
                manager.startMonitoring(for: region)
            }
        }
    }

    /// База камер прочитана — разобрать входы, пришедшие до неё.
    func processPendingRegionEnters() {
        for id in pendingRegionEnters.drain() { handleEnter(regionID: id) }
    }

    func handleEnter(regionID: String) {
        // Пока идёт непрерывный GPS — в поездке или при открытом экране, включая
        // экран машины, — о камере говорит движок по точному расстоянию. Геозона
        // дала бы вторым, отставшим на сотни метров, пуш о том же самом.
        guard !isTripActive, !isForeground else { return }
        guard repository.isDatabaseLoaded else {
            pendingRegionEnters.enter(regionID)
            return
        }
        guard let id = Self.cameraID(from: regionID),
              !alertedCameraIDs.contains(id),
              let camera = repository.cameras.first(where: { $0.id == id }),
              // Истёкшая отметка водителей в тихом фоне (опроса нет) — не
              // пугаем (сценарий S5, 20.10).
              !camera.isExpiredMobile(at: Date()),
              settings.backgroundAlerts.allows(camera) else { return }
        // Пробуждение — повод перечитать, не подключена ли машина.
        onQuietWake?()
        // Вход в геозону — ещё не доказательство езды: систему будит Wi-Fi и
        // вышки с ошибкой 100–500 м, и телефон, лежащий дома у края круга,
        // «входит» в него от дрожания (владелец, 21.10: «Камера через 550 м»
        // дома). Решают ворота QuietAlertGate (26.1).
        //
        // Live Activity здесь не обновляем: она живёт только в поездке
        // (startIfNeeded зовётся из startTrip), а сюда мы попадаем строго вне
        // её — update() всегда выходил по guard, ветка была мёртвой и только
        // читалась как живой путь.
        evaluateQuietEntry(camera)
    }

    func handleExit(regionID: String) {
        // Вошли и вышли, пока читалась база, — камера уже позади, не пугаем.
        pendingRegionEnters.exit(regionID)
        if !isTripActive, !isForeground { onQuietWake?() }
        guard let id = Self.cameraID(from: regionID) else { return }
        // Повтор об этой же камере после выхода сторожит журнал тихого фона
        // (quietAlertRepeatSeconds), а не этот набор: дрожание дома входило и
        // выходило, и каждый новый вход был новым пушем.
        alertedCameraIDs.remove(id)
    }

    // MARK: - Идентификаторы регионов

    static func regionID(for cameraID: Int) -> String { "camera-\(cameraID)" }

    static func cameraID(from identifier: String) -> Int? {
        let prefix = "camera-"
        guard identifier.hasPrefix(prefix) else { return nil }
        return Int(identifier.dropFirst(prefix.count))
    }
}
