//
//  LocationService+Announcer.swift
//  RadarMap
//
//  Голос о камерах: план фразы, движок тревоги, отложенная фраза, зоны треног.
//

import Foundation
import AVFAudio
import CoreLocation
import Observation
import os
import UIKit

extension LocationService {

    /// «впереди» / «впереди справа» / «впереди слева» — для голосового предупреждения.
    var directionPhrase: String {
        switch nearestDirection {
        case .right, .behindRight: return String(localized: "впереди справа")
        case .left, .behindLeft:   return String(localized: "впереди слева")
        default:                   return String(localized: "впереди")
        }
    }

    /// Ползём: пробка или светофор. Голос в этот момент бесполезен — камеру
    /// впереди показывает панель, а решать водителю пока нечего.
    var isCrawling: Bool { speedKmh < AppConfig.voiceMinSpeedKmh }

    /// Градус оповещения: тишина (тумблер или пробка) → короткая фраза (город) →
    /// полная фраза (трасса) → крик (устойчивое превышение или внезапная точка).
    /// Именно УСТОЙЧИВОЕ превышение: мгновенный флаг щёлкает от шума GPS, и
    /// «превысил на 1 км/ч» поднимал спокойный анонс до сирены.
    /// Скажем ли мы сейчас про камеру впереди. Если да — отдельную фразу про
    /// превышение подавляем: камера важнее, и говорить надо о ней одной.
    var willSpeakAboutCameraAhead: Bool {
        guard let camera = nearestCamera, let distance = distanceToNearest,
              distance <= effectiveAlertRadius else { return false }
        return voicePlan(for: camera, crawling: isCrawling).voice != .none
    }

    /// Пересчитать «свои» камеры по истории. Зовётся на старте поездки:
    /// история за 30 дней меняется медленно, на каждом тике это лишняя работа.
    func refreshFamiliarCameras() {
        // Выключили умную тишину — забываем список: гейт в VoiceDirector
        // работает по нему, и пустое множество и есть «говорить обо всех».
        guard settings.smartSilence else {
            familiarCameraIDs = []
            return
        }
        familiarCameraIDs = CameraFamiliarity.familiarIDs(history: trip.history, now: Date())
    }

    func voicePlan(for camera: Camera, crawling: Bool) -> VoiceDirector.Plan {
        VoiceDirector.decide(situation(for: camera, crawling: crawling))
    }

    /// Обстановка для арбитра: всё, что он должен видеть разом, собирается
    /// здесь. Раньше эти же факты читались из трёх мест в разные моменты
    /// времени — отсюда и брались фразы внахлёст и молчание о камере.
    func situation(for camera: Camera, crawling: Bool) -> VoiceDirector.Situation {
        let context: AlertPolicy.Context = switch settings.alertMode {
        case .auto: alertContext
        case .city: .city
        case .highway: .highway
        }
        // Превышение — только УСТОЙЧИВОЕ: мгновенный флаг щёлкает от шума GPS,
        // и «превысил на 1 км/ч» поднимал спокойный анонс до сирены.
        let over: Double? = if speedLimits?.isOverspeedingSustained == true,
                               let limit = speedLimits?.currentLimit {
            speedKmh - Double(limit)
        } else {
            nil
        }
        return VoiceDirector.Situation(
            mode: settings.voiceMode,
            context: context,
            isSudden: camera.kind.isSudden,
            isFamiliar: familiarCameraIDs.contains(camera.id),
            overKmh: over,
            limitKmh: speedLimits?.currentLimit,
            isCrawling: crawling)
    }

    /// Оповещения о приближении: решение принимает AlertEngine (чистый, тестируемый),
    /// здесь — только исполнение: звук, хаптика, голос, уведомление.
    /// nearestCamera уже отфильтрована коридором дороги (isOnOurRoad): о камерах
    /// позади, на параллельных и перпендикулярных улицах не предупреждаем.
    func runAlertEngine() {
        guard let camera = nearestCamera, let distance = distanceToNearest else { return }
        guard let decision = alertEngine.evaluate(cameraID: camera.id, distance: distance,
                                                  radius: effectiveAlertRadius,
                                                  moving: isDirectionalFilteringActive) else { return }

        let policy = voicePlan(for: camera, crawling: isCrawling)

        // Сирена — только в срочном режиме: спокойный анонс не пищит.
        if settings.soundEnabled, policy.beeps { alerts.beep(count: decision.level) }
        // Вибрация никому не мешает и работает в беззвучном режиме: эскалация
        // «мягкий тук → резкий у камеры» — только в срочном, иначе один тук на входе.
        if policy.escalates {
            alerts.haptic(level: decision.level)
        } else if decision.isFirst {
            alerts.haptic(level: 1)   // спокойный режим: один тук на камеру
        }

        // Баннер и голос — один раз на камеру, на ПЕРВОМ оповещении о ней. Раньше
        // условием был level == 1, но камеру бывает видно поздно (поворот прямо
        // перед ней, возврат сигнала, соседняя была ближе) — она входит сразу на
        // втором-третьем уровне, и приложение молчало о ней совсем.
        guard decision.isFirst else { return }
        onAlertFired?()
        // Дистанция ПЕРВОГО предупреждения: по ней потом видно, успели мы
        // сказать заранее или уже на самой камере. Только в поездке — иначе
        // открытое в кармане приложение копило бы «предупреждения впустую»
        // о камерах, мимо которых никто не ехал, и охват выглядел бы провальным.
        if isTripActive { alertRecall.noteAlert(cameraID: camera.id, distance: distance) }
        // В свёрнутом виде (поездка в фоне) — уведомление зажигает экран и вибрирует.
        // Пользователь управляет: все камеры / только радары / выключено.
        if !isForeground, settings.backgroundAlerts.allows(camera) {
            notifier.notifyApproaching(camera, distanceMeters: distance)
        }
        // Голос о камере — и в энергосбережении (сценарий S1, 20.10): до этого
        // режим Low Power глушил именно камеры, а манёвры, лимиты и пробки
        // говорили. Фраза стоит секунды синтеза; экономит энергосбережение
        // на GPS и карте, а оповещения о камерах не трогает ничто.
        guard settings.voiceEnabled else { return }
        guard policy.voice != .none else {
            // Промолчали из-за пробки — это ОТСРОЧКА, а не отмена: камера,
            // вошедшая в радиус пока мы разгоняемся от светофора, иначе осталась
            // бы без голоса совсем (уровень уже зачтён, второй раз не придёт).
            // Отложить фразу «поедем — скажу» имеет смысл только там, где она
            // вообще прозвучала бы: в «Умно» и «Молча» голоса нет по замыслу.
            if policy.postpone { postponedVoice = camera.id }
            return
        }
        speak(about: camera, distance: distance, policy: policy)
    }

    /// Сказать про камеру, отложенную пробкой, как только поехали. Зовётся с
    /// каждого тика — дешёвая проверка одного идентификатора.
    func speakPostponedVoice() {
        guard let id = postponedVoice else { return }
        guard let camera = nearestCamera, camera.id == id,
              let distance = distanceToNearest, distance <= effectiveAlertRadius else {
            postponedVoice = nil   // камеру проехали или сменили — отсрочка не нужна
            return
        }
        guard !isCrawling else { return }   // всё ещё стоим
        postponedVoice = nil
        guard settings.voiceEnabled else { return }
        let policy = voicePlan(for: camera, crawling: false)
        guard policy.voice != .none else { return }
        speak(about: camera, distance: distance, policy: policy)
    }

    func speak(about camera: Camera, distance: CLLocationDistance,
                       policy: VoiceDirector.Plan) {
        // Про эту камеру уже сказали групповой фразой на предыдущей — молчим
        // (тук и баннер при этом сработали, камера не потерялась).
        if voicedInGroup.remove(camera.id) != nil { return }
        let group = clusteredCameras
        voicedInGroup.formUnion(group.map(\.id))
        alerts.speak(announcement(for: camera, distance: distance,
                                  urgent: policy.voice == .urgent,
                                  speaksLimit: policy.speaksLimit,
                                  brief: policy.isBrief,
                                  groupCount: group.count))
        // Считаем ТОЛЬКО здесь: это единственное место, где фраза о камере
        // действительно уходит в синтезатор. Считать раньше — считать
        // намерения, а их у нас и так девятнадцать на поездку.
        onCameraSpoken?(policy.voice.counterName)
    }

    /// «Здесь часто ставят треногу» — один раз за поездку на точку и только
    /// при превышении. Решение целиком в чистом `HotspotAlert` (тесты там же);
    /// здесь — доступ к живым данным и собственно голос.
    ///
    /// Почему это НЕ ведёт себя как камера: у камеры молчание хуже лишнего
    /// сигнала, поэтому она предупреждает и при сомнении. Здесь сомнение
    /// означает молчание — подсказка про прошлое, выданная за факт, стоит
    /// доверия ко всему приложению. Точка при этом остаётся на карте: показать
    /// и сказать — разные вещи.
    func announceHotspotIfNeeded(from coordinate: CLLocationCoordinate2D) {
        guard let hotspots, !hotspots.spots.isEmpty, settings.voiceMode != .off else { return }
        let situation = HotspotAlert.Situation(
            coordinate: coordinate,
            course: currentCourse,   // уже прошёл LocationFilter; < 0 — курса нет
            isTripActive: isTripActive,
            isOverspeeding: speedLimits?.isOverspeeding ?? false,
            hintsEnabled: settings.tripodHints)
        guard let spot = HotspotAlert.spotToAnnounce(in: hotspots.spots, situation: situation,
                                                     alreadyVoiced: voicedHotspots) else { return }
        voicedHotspots.insert(spot.key)
        alerts.speak(HotspotAlert.phrase(for: spot))
    }

    /// «Впереди ремонт дороги» (12б.5): решение — в чистом RoadEventRules,
    /// здесь живые данные и голос. Ниже камеры: при оповещении о камере
    /// молчит, событие останется «несказанным» до следующего фикса.
    func announceRoadEventIfNeeded(from coordinate: CLLocationCoordinate2D) {
        guard isTripActive, settings.voiceEnabled, alertLevel == 0,
              let events = roadEvents?(), !events.isEmpty else { return }
        // Синтезатор ставит фразы в очередь: камера, вошедшая в радиус через
        // тик, ждала бы конца «Впереди ремонт дороги». Камера ближе радиуса
        // плюс несколько секунд пути — молчим, событие скажем после неё.
        if let distance = distanceToNearest,
           distance <= effectiveAlertRadius + speedKmh / 3.6 * AppConfig.roadEventCameraGapSeconds { return }
        guard let event = RoadEventRules.ahead(of: coordinate, course: currentCourse, events: events,
                                               voiced: voicedRoadEvents, now: Date()) else { return }
        voicedRoadEvents.insert(event.id)
        alerts.speak(RoadEventRules.phrase(for: event))
    }

    /// Фраза предупреждения. Спокойная — как у навигатора, только тип и округлённое
    /// расстояние; про скорость и лимит говорим лишь в срочном режиме, потому что
    /// именно превышение и есть причина повышать голос.
    ///
    /// `brief` — городской вариант в два слова: камеры идут одна за другой, и
    /// полная фраза на каждую превращается в болтовню. `groupCount` — сколько
    /// камер стоит вплотную за этой: о них говорим здесь же, одной фразой.
    func announcement(for camera: Camera, distance: CLLocationDistance,
                              urgent: Bool, speaksLimit: Bool = false,
                              brief: Bool = false, groupCount: Int = 0) -> String {
        // Округляем как манёвры маршрута: «через 743 метра» звучит по-роботски.
        let step: Double = distance >= 400 ? 100 : 50
        let rounded = Int((distance / step).rounded() * step)
        var phrase: String
        if groupCount > 0 {
            phrase = String(format: String(localized: "Камеры впереди, %lld метров"), rounded)
        } else if brief {
            phrase = String(format: String(localized: "%@, %lld метров"),
                            camera.kind.shortName, rounded)
        } else if camera == nearestCamera ? nearestViaRoute : isCameraOnRoute(camera) {
            phrase = String(format: String(localized: "По маршруту %@ через %lld метров"),
                            camera.kind.displayName.lowercased(), rounded)
        } else {
            phrase = String(format: String(localized: "%@ %@, %lld метров"),
                            camera.kind.displayName, directionPhrase, rounded)
        }
        // Неподтверждённая отметка водителей: предупреждаем всегда (тишина
        // хуже лишнего сигнала), но слух не выдаём за факт — называем источник.
        // Атрибуция честнее «возможно»: она объясняет, откуда точка взялась, и
        // заодно делает сообщество видимым — водитель слышит, что чужие отметки
        // работают, и начинает отмечать сам. Множественное число безопасно:
        // «отметка водителей» — это категория источника, а не счёт людей.
        // Групповую фразу не трогаем: там несколько камер.
        if camera.isUnconfirmedMobile, groupCount == 0 {
            phrase = String(format: String(localized: "Отметка водителей: %@"),
                            phrase.prefix(1).lowercased() + phrase.dropFirst())
        }
        // Срочно — полная картина: своя скорость и лимит. Иначе (трасса) —
        // только лимит: «здесь 60» помогает, перечисление своей скорости при
        // спокойной езде лишнее.
        if urgent {
            if let limit = speedLimits?.currentLimit {
                phrase += String(format: String(localized: ". Ваша скорость %lld, лимит %lld"),
                                 Int(speedKmh.rounded()), limit)
            } else if speedKmh >= AppConfig.speakSpeedThresholdKmh {
                phrase += String(format: String(localized: ". Ваша скорость %lld"),
                                 Int(speedKmh.rounded()))
            }
        } else if speaksLimit, let limit = speedLimits?.currentLimit {
            phrase += String(format: String(localized: ", здесь %lld"), limit)
        }
        return phrase
    }
}
