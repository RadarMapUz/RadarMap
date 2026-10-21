//
//  LocationService+VoiceEvent.swift
//  RadarMap
//
//  Фраза о камере событием — для записанного голоса (этап 16).
//
//  Двойник `announcement(for:…)`: те же входы, прочитанные в тот же момент.
//  Разойтись им не дают два предохранителя: решения собраны в чистом
//  `VoiceEvent.cameraAnnouncement` (тесты), а перед звуком событие
//  рендерится обратно в текст и сверяется с фразой (`RecordedVoice.plan`) —
//  при расхождении говорит синтезатор.
//

import CoreLocation
import Foundation

extension LocationService {

    func announcementEvent(for camera: Camera, distance: CLLocationDistance,
                           urgent: Bool, speaksLimit: Bool = false,
                           brief: Bool = false, groupCount: Int = 0) -> VoiceEvent? {
        VoiceEvent.cameraAnnouncement(
            type: camera.kind, distance: distance, urgent: urgent,
            speaksLimit: speaksLimit, brief: brief, groupCount: groupCount,
            onRoute: { camera == self.nearestCamera ? self.nearestViaRoute : self.isCameraOnRoute(camera) },
            direction: nearestDirection,
            unconfirmed: camera.isUnconfirmedMobile,
            currentLimit: speedLimits?.currentLimit,
            speedKmh: speedKmh,
            speakSpeedThreshold: AppConfig.speakSpeedThresholdKmh)
    }
}
