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

        /// `roadClass` — класс дороги камеры впереди (из базы). Сигнал мгновенный:
        /// средней скорости нужно около трёх минут, чтобы устояться, а «trunk»
        /// или «residential» известны сразу.
        mutating func update(roadLimitKmh: Int?, camerasWithin3km: Int,
                             speedKmh: Double, roadClass: RoadClass = .unknown,
                             now: Date = Date()) {
            avgSpeedKmh = avgSpeedKmh == 0 ? speedKmh : avgSpeedKmh * 0.985 + speedKmh * 0.015

            var votes = 0
            if let roadLimitKmh {
                if roadLimitKmh >= AppConfig.highwayLimitKmh { votes += 2 }      // лимит — самый сильный сигнал
                else if roadLimitKmh <= AppConfig.cityLimitKmh { votes -= 2 }
            }
            if roadClass.isHighway { votes += 2 }
            else if roadClass.isCityStreet { votes -= 2 }
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

    /// Насколько громко исполнять сработавший уровень AlertEngine.
    /// Три градуса вместо прежнего «да/нет»: сплошной крик о каждой камере
    /// одинаково громко — то же самое, что не предупреждать вовсе, потому что
    /// водитель перестаёт различать важное.
    enum Style: Equatable {
        /// Ни звука, ни голоса: камеру показывают HUD, полоска приближения и
        /// один мягкий тук. Городская сетка камер, едем в лимите.
        case silent
        /// Один спокойный анонс на входе в радиус — без бипов и без эскалации.
        case calm
        /// Полная эскалация: бипы по уровням, голос, резкая вибрация.
        case urgent
    }

    struct Decision: Equatable {
        let style: Style
        /// Пищать ли сиреной — только в срочном режиме.
        var beeps: Bool { style == .urgent }
        /// Говорить ли голосом — спокойно или срочно, но не в тишине.
        var voice: Bool { style != .silent }
        /// Наращивать ли сигналы по мере приближения (иначе один раз на входе).
        var escalates: Bool { style == .urgent }
    }

    /// Матрица решений. Приоритет сверху вниз:
    /// 1. Внезапная точка (передвижной, тренога, ДТП) — всегда срочно: водитель
    ///    не может её знать заранее, и это ровно тот случай, ради которого
    ///    оповещения вообще нужны.
    /// 2. Устойчивое превышение у камеры — срочно: сейчас будет штраф.
    /// 3. Тумблер «голос только при превышении» — тишина, раз не превышаем.
    /// 4. Трасса — спокойный анонс: камер мало, знать о каждой полезно.
    /// 5. Город — тишина: камер сотни, крик о каждой превращается в белый шум.
    static func decision(mode: AlertMode, detected: Context,
                         isSuddenCamera: Bool, isOverspeeding: Bool,
                         voiceOnlyWhenOverspeeding: Bool) -> Decision {
        if isSuddenCamera || isOverspeeding { return Decision(style: .urgent) }
        if voiceOnlyWhenOverspeeding { return Decision(style: .silent) }
        let context: Context = switch mode {
        case .auto: detected
        case .city: .city
        case .highway: .highway
        }
        return Decision(style: context == .highway ? .calm : .silent)
    }
}
