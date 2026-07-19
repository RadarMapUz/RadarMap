//
//  AlertPolicy.swift
//  RadarMap
//
//  Умный режим оповещений. В городе камер сотни — голос на каждую превращается
//  в белый шум, и его выключают навсегда; на трассе камер мало, скорости и
//  штрафы высокие — говорить надо про каждую и заранее. Детектор сам понимает
//  контекст по лимиту дороги, плотности камер и средней скорости; политика
//  решает, чем исполнять сработавший уровень AlertEngine. Чистая логика,
//  покрыта тестами (AlertPolicyTests).
//

import Foundation

nonisolated enum AlertPolicy {
    enum Context: String {
        case city, highway
    }

    /// Детектор «город/трасса» с гистерезисом: решение по голосам трёх сигналов,
    /// переключение не чаще AppConfig.alertContextSwitchSeconds — светофор на
    /// трассе или короткий проспект в городе не должны дёргать режим.
    struct Detector {
        private(set) var context: Context = .city   // безопасный дефолт — тихий город
        private var lastSwitchAt = Date.distantPast
        /// Средняя скорость: EMA с окном в пару минут на секундных тиках.
        private(set) var avgSpeedKmh: Double = 0

        mutating func update(roadLimitKmh: Int?, camerasWithin3km: Int,
                             speedKmh: Double, now: Date = Date()) {
            avgSpeedKmh = avgSpeedKmh == 0 ? speedKmh : avgSpeedKmh * 0.985 + speedKmh * 0.015

            var votes = 0
            if let roadLimitKmh {
                if roadLimitKmh >= AppConfig.highwayLimitKmh { votes += 2 }      // лимит — самый сильный сигнал
                else if roadLimitKmh <= AppConfig.cityLimitKmh { votes -= 2 }
            }
            if avgSpeedKmh >= AppConfig.highwayAvgSpeedKmh { votes += 1 }
            else if avgSpeedKmh > 0, avgSpeedKmh <= AppConfig.cityAvgSpeedKmh { votes -= 1 }
            if camerasWithin3km >= AppConfig.cityCameraDensity { votes -= 1 }    // плотная сетка камер = город
            else if camerasWithin3km <= 1 { votes += 1 }

            let target: Context? = votes >= 2 ? .highway : votes <= -2 ? .city : nil
            guard let target, target != context,
                  now.timeIntervalSince(lastSwitchAt) >= AppConfig.alertContextSwitchSeconds
            else { return }
            context = target
            lastSwitchAt = now
        }
    }

    /// Чем исполнять уровень приближения. Вибрация — всегда (не мешает никому);
    /// звук и голос — по контексту.
    struct Decision: Equatable {
        let sound: Bool
        let voice: Bool
    }

    /// Город: голос только про внезапное (передвижной/тренога) или при превышении —
    /// остальное показывают HUD, полоска и лёгкий тук. Трасса: полная эскалация.
    static func decision(mode: AlertMode, detected: Context,
                         isSuddenCamera: Bool, isOverspeeding: Bool) -> Decision {
        let context: Context = switch mode {
        case .auto: detected
        case .city: .city
        case .highway: .highway
        }
        if context == .highway { return Decision(sound: true, voice: true) }
        let audible = isSuddenCamera || isOverspeeding
        return Decision(sound: audible, voice: audible)
    }
}
