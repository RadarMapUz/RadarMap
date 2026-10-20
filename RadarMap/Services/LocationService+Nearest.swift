//
//  LocationService+Nearest.swift
//  RadarMap
//
//  Ближайшая камера: гейты «наша дорога», маршрут, направление, ступень тревоги.
//

import Foundation
import AVFAudio
import CoreLocation
import Observation
import os
import UIKit

extension LocationService {

    /// Пересчёт обоих флагов. Зовётся из didSet каждого входа (скорость,
    /// дистанция, сигнал, поездка, контекст), поэтому пропустить путь
    /// обновления нельзя; запись — только на смене значения.
    func refreshApproachFlags() {
        let radius = effectiveAlertRadius
        let approaching = Self.isApproaching(distance: distanceToNearest, speedKmh: speedKmh,
                                             radius: radius, signalStale: isSignalStale)
        if approaching != isApproachingCamera { isApproachingCamera = approaching }
        let level = Self.alertLevel(distance: distanceToNearest, radius: radius,
                                    tripActive: isTripActive)
        if level != alertLevel { alertLevel = level }
    }

    nonisolated static func isApproaching(distance: CLLocationDistance?, speedKmh: Double,
                                          radius: CLLocationDistance, signalStale: Bool) -> Bool {
        guard !signalStale, let distance,
              speedKmh >= AppConfig.directionalMinSpeedKmh else { return false }
        return distance <= radius
    }

    nonisolated static func alertLevel(distance: CLLocationDistance?, radius: CLLocationDistance,
                                       tripActive: Bool) -> Int {
        guard tripActive, let d = distance else { return 0 }
        return AlertEngine.level(distance: d, radius: radius)
    }

    /// Текущее состояние для Live Activity.
    var activityState: CameraActivityAttributes.ContentState {
        let now = Date()
        let ghost = activityGhost?()
        return CameraActivityAttributes.ContentState(
            nearestTitle: nearestCamera?.displayTitle,
            nearestSymbol: nearestCamera?.kind.symbolName ?? "checkmark.shield.fill",
            distanceMeters: distanceToNearest,
            arrivesAt: LiveActivityService.arrival(distance: distanceToNearest, speedKmh: speedKmh, now: now),
            since: now,
            etaClock: ghost?.clock,
            etaCaption: ghost?.caption,
            etaAlert: ghost?.alert,
            limitKmh: speedLimits?.currentLimit,
            alertLevel: alertLevel
        )
    }

    /// Обстановка для гейтов «наша ли камера» (чистый модуль LocationGates).
    /// Собирается здесь и только здесь: гейт не должен уметь дотянуться до
    /// сервиса, иначе он перестанет быть проверяемой функцией от геометрии.
    ///
    /// Координата — параметром, а не из `currentCoordinate`: гейты зовутся с
    /// точкой ТЕКУЩЕГО тика, и подмена её на свойство развела бы решение о
    /// камере и точку, для которой оно принимается.
    func gateSituation(at coordinate: CLLocationCoordinate2D) -> LocationGates.Situation {
        LocationGates.Situation(coordinate: coordinate, course: currentCourse,
                                speedKmh: speedKmh, horizontalAccuracy: horizontalAccuracy,
                                context: alertContext)
    }

    /// Фильтр направления активен, когда едем достаточно быстро и GPS-курс достоверен.
    var isDirectionalFilteringActive: Bool {
        LocationGates.isFilteringActive(gateSituation(at: currentCoordinate ?? .init()))
    }

    /// Камера «наша». Вся политика — в `LocationGates` (чистый модуль со своими
    /// тестами); сервис отвечает только за то, что гейт вообще не может знать
    /// сам: лежит ли камера на построенном маршруте.
    func isOnOurRoad(_ camera: Camera, from coordinate: CLLocationCoordinate2D) -> Bool {
        LocationGates.isOnOurRoad(camera, in: gateSituation(at: coordinate),
                                  isOnRoute: isCameraOnRoute(camera))
    }

    /// Пересчёт направления на ближайшую камеру — вызывается на каждом GPS-тике.
    func recomputeDirection() {
        guard isDirectionalFilteringActive,
              let camera = nearestCamera,
              let coordinate = currentCoordinate else {
            // Пишем только на изменение: @Observable будит читателей на каждую
            // запись, даже того же nil (аудит энергии 19.10).
            if relativeBearingToNearest != nil { relativeBearingToNearest = nil }
            bearingSmoother.reset()
            return
        }
        if nearestViaRoute {
            if relativeBearingToNearest != 0 { relativeBearingToNearest = 0 }   // на маршруте — прямо по ходу
            bearingSmoother.reset()
            return
        }
        let bearing = GeoMath.bearing(from: coordinate, to: camera.coordinate)
        let raw = (bearing - currentCourse + 360).truncatingRemainder(dividingBy: 360)
        relativeBearingToNearest = bearingSmoother.update(raw)
    }

    /// Ближайшая камера лежит на активном маршруте (в его коридоре).
    func isCameraOnRoute(_ camera: Camera) -> Bool {
        route?.routeCamera(id: camera.id) != nil
    }

    /// Направление на ближайшую камеру для голоса/HUD (учитывает мёртвую зону и маршрут).
    var nearestDirection: CameraDirection? {
        relativeBearingToNearest.map { CameraDirection.classify(relativeBearing: $0) }
    }

    /// Обнулить «ближайшую» без лишних оповещений наблюдателям: @Observable не
    /// сравнивает значения, и голая перезапись тем же nil будила бы всех
    /// подписчиков (HUD, карту, CarPlay) на каждом тике без камеры впереди —
    /// то есть почти всегда.
    func clearNearest() {
        if nearestCamera != nil { nearestCamera = nil }
        if distanceToNearest != nil { distanceToNearest = nil }
        nearestViaRoute = false
        if !clusteredCameras.isEmpty { clusteredCameras = [] }
    }

    /// `fromFix` — вызов с настоящего фикса GPS (handleLocation). Учёт
    /// «проехали / снова подъезд» — только по ним: пересборка окна (база,
    /// чужие отметки, возврат на экран) повторяет последний фикс, и один кривой
    /// курс засчитывался бы дважды (ревью 20.10).
    func recomputeNearest(from coordinate: CLLocationCoordinate2D, fromFix: Bool = false) {
        guard !trackedCameras.isEmpty else { clearNearest(); return }
        // Тот же фикс второй раз (iOS повторяет кэшированный после каждого
        // startUpdatingLocation — экран, машина, питание) — не новый шаг серии
        // «проехали / снова впереди» (ревью S4, третий круг).
        let newFix = fromFix && (geometryFixTime.map { lastFixTime > $0 } ?? true)
        if newFix { geometryFixTime = lastFixTime }
        // Сначала дешёвая дистанция по всему окну, и только потом дорогая проверка
        // «наша ли это дорога» — по возрастанию, до первой подходящей. Результат
        // тот же, что у минимума по отфильтрованному списку, но геометрию камеры
        // (кусок дороги, ось, коридор) считаем раз-два на тик, а не 150 раз.
        // fastDistance вместо CLLocation: без аллокаций, и PassTracking меряет
        // траверз тем же способом — цифры на HUD и в проездах сходятся.
        // Буфер переиспользуется между тиками (без новой аллокации на фикс).
        // Полная сортировка оставлена сознательно: окно ≤ trackedCamerasLimit,
        // это микросекунды, а частичный выбор на пути тревоги — лишний риск
        // (аудит энергии 19.10, 2.12).
        var candidates = nearestBuffer
        nearestBuffer = []   // единственная ссылка — иначе removeAll скопирует буфер
        candidates.removeAll(keepingCapacity: true)
        defer { nearestBuffer = candidates }
        // Охват предупреждений меряется по ГЕОГРАФИИ: проехали ближе порога
        // траверса — камера была наша, и молчание о ней обязано попасть в счёт.
        // Ни маршрут, ни гейты, ни правила записи проезда здесь не участвуют:
        // мерить работу конвейера его же решениями значит всегда получать сто
        // процентов. Только в поездке — открытое приложение в кармане пассажира
        // камеры не «проезжает», — и только по ГОДНОМУ фиксу: seedContext
        // зовёт нас же по грубой точке, где ни алертов, ни зачёта проездов нет
        // (см. его комментарий). Кэшированный фикс у камеры иначе записался бы
        // проездом без предупреждения, то есть выдуманным промахом.
        let countsPasses = isTripActive && !isPositionCoarse
        let situation = gateSituation(at: coordinate)
        for camera in trackedCameras {
            let straight = GeoMath.fastDistance(coordinate.latitude, coordinate.longitude,
                                                camera.lat, camera.lon)
            if countsPasses, straight <= PassGeometry.traverseLimit(for: camera) {
                alertRecall.notePassed(cameraID: camera.id)
            }
            let announced = alertEngine.isAnnounced(camera.id)
            // Проеханные (сценарий S4): о ком сказали, у кого были и кто теперь
            // явно позади — следующий подъезд к ним (разворот, круг) будет
            // новым. Только по годному фиксу — грубая точка из seedContext
            // «проезжать» камеры не вправе. Сказано о единицах камер.
            if announced, newFix, !isPositionCoarse {
                let atTraverse = straight <= max(PassGeometry.traverseLimit(for: camera),
                                                 AppConfig.alertTraverseMeters)
                if atTraverse {
                    alertEngine.noteApproach(camera.id, distance: straight, at: coordinate,
                                             course: situation.course)
                }
                alertEngine.noteGeometry(camera.id, atTraverse: atTraverse,
                                         behind: LocationGates.isClearlyBehind(camera, in: situation),
                                         ahead: alertEngine.isPassed(camera.id)
                                            && LocationGates.isReapproach(camera, in: situation,
                                                                          passLine: alertEngine.passLine(camera.id)))
            }
            // Камера уехала назад по маршруту — стоя не пугаем ею, в движении
            // она снова камера «как все» (маршрут с разворотом).
            guard let candidate = LocationGates.candidateDistance(straight: straight,
                                                                  routeRemaining: routeRemaining(to: camera),
                                                                  announced: alertEngine.isAnnounced(camera.id),
                                                                  in: situation) else { continue }
            candidates.append((camera, candidate.distance, candidate.onRoute))
        }
        candidates.sort { $0.distance < $1.distance }
        // В движении HUD показывает ближайшую камеру НА НАШЕЙ ДОРОГЕ впереди;
        // камеры позади и с соседних улиц не пугают зря.
        guard let index = candidates.firstIndex(where: {
            LocationGates.isOnOurRoad($0.camera, in: situation, isOnRoute: $0.onRoute)
        }) else { clearNearest(); return }
        let found = candidates[index]
        nearestViaRoute = found.onRoute
        // Камера чаще всего ТА ЖЕ, что тик назад: перезапись тем же значением
        // всё равно будит всех наблюдателей @Observable, и до этой проверки
        // карта с двумя сотнями маркеров перерисовывалась каждую секунду.
        if nearestCamera != found.camera { nearestCamera = found.camera }
        distanceToNearest = found.distance
        // Камеры, стоящие вплотную за ближайшей: на перекрёстке их две-три, и
        // сказать о них надо одной фразой. Проверяем только тех, кто попал в
        // группу по расстоянию — это ноль-два лишних вычисления геометрии.
        clusteredCameras = candidates[(index + 1)...]
            .prefix { $0.distance <= found.distance + AppConfig.voiceGroupMeters }
            .filter { LocationGates.isOnOurRoad($0.camera, in: situation, isOnRoute: $0.onRoute) }
            .map(\.camera)
    }

    /// Остаток до камеры ПО МАРШРУТУ; nil — камера не на активном маршруте.
    /// По прямой петля развязки или объезд дают 300 м там, где по дороге 2 км, —
    /// и приложение предупреждало о камере, до которой ещё ехать и ехать.
    /// Остаток по маршруту до его камеры — только пока мы на маршруте.
    /// Съехали (а без сети перестроиться нельзя) — прогресс застыл на
    /// проекции, и камеры старой линии «по маршруту» были нашими без
    /// условий: заслоняли настоящую камеру впереди на новой дороге и
    /// звучали сами (сценарий S7, 20.10). Тогда они — как все: по прямой и
    /// через гейты.
    func routeRemaining(to camera: Camera) -> CLLocationDistance? {
        guard let route, route.isActive, !route.isOffRoute,
              let onRoute = route.routeCamera(id: camera.id)
        else { return nil }
        return onRoute.distanceAlong - route.progressAlong
    }

    /// Умный радиус оповещения — растёт со скоростью (см. AlertEngine).
    ///
    /// Не приватный: этот же радиус обязан показывать экран. Полноэкранное
    /// предупреждение брало базовые 400 м из настроек, а тревога поднималась
    /// по эффективному — на 130 км/ч это 794 м, и кольцо приближения честно
    /// показывало ноль первые 394 метра, то есть почти одиннадцать секунд.
    var effectiveAlertRadius: CLLocationDistance {
        AlertEngine.effectiveRadius(speedKmh: speedKmh, baseRadius: settings.alertRadius,
                                    context: alertContext)
    }

    /// 0…1 — насколько глубоко вошли в радиус оповещения (полоска приближения в HUD).
    /// nil — ближайшая камера ещё вне радиуса, полоска не нужна.
    var approachProgress: Double? {
        guard !isSignalStale, let distance = distanceToNearest,
              distance < effectiveAlertRadius else { return nil }
        return 1 - distance / max(effectiveAlertRadius, 1)
    }
}
