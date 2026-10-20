//
//  LocationService+RoadWeather.swift
//  RadarMap
//
//  «На перевале Камчик туман» (19.2): решение — в чистом RoadWeatherAlert,
//  «уже сказано» и баннер — в RoadWeatherService, здесь живые данные и голос.
//

import CoreLocation
import Foundation

extension LocationService {

    /// Камера впереди занимает голос и экран: в радиусе оповещения, о ней
    /// сейчас скажут, или до радиуса меньше `roadEventCameraGapSeconds` пути —
    /// синтезатор ставит фразы в очередь, и камера ждала бы конца фразы о
    /// погоде. То же правило, что у событий дороги.
    var isCameraBusyForRoadNotes: Bool {
        if alertLevel > 0 || willSpeakAboutCameraAhead { return true }
        guard let distance = distanceToNearest else { return false }
        return distance <= effectiveAlertRadius + speedKmh / 3.6 * AppConfig.roadEventCameraGapSeconds
    }

    /// Только в поездке. Пока камера занята — погода ждёт и не теряется:
    /// решение «подождать» не тратит единственную фразу о перевале.
    func announceRoadWeatherIfNeeded(from coordinate: CLLocationCoordinate2D) {
        guard isTripActive, let roadWeather else { return }
        let notice = roadWeather.notice(cameraBusy: isCameraBusyForRoadNotes) { [self] in
            // Линия маршрута — лениво: нужна раз в roadWeatherCheckSeconds.
            let path = route?.isActive == true
                ? route?.pathAhead(from: coordinate, meters: AppConfig.roadWeatherAnnounceMeters.upperBound
                                   + AppConfig.roadWeatherGroupSpanMeters)
                : nil
            return RoadWeatherAlert.Situation(position: coordinate, course: currentCourse, speedKmh: speedKmh,
                                              onHighway: alertContext == .highway, pathAhead: path)
        }
        guard let notice, settings.voiceEnabled else { return }
        alerts.speak(notice.spoken)
    }
}
