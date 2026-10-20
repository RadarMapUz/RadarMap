//
//  LocationService+Trip.swift
//  RadarMap
//
//  Поездка: старт и стоп, склейка, водитель или пассажир, запись проездов.
//

import Foundation
import AVFAudio
import CoreLocation
import Observation
import os
import UIKit

extension LocationService {

    /// Сессия пассажира, пережившая перезапуск: только пока срок не вышел.
    nonisolated static func passengerSessionRestored(until: Date?, now: Date) -> Bool {
        guard let until else { return false }
        return until > now && until.timeIntervalSince(now) <= AppConfig.passengerSessionMaxSeconds
    }

    /// Начать поездку. `auto` — старт от CoreMotion: в незнакомой машине зададим
    /// вопрос «вы за рулём?» (в своей — CarPlay/знакомая магнитола — молча).
    func startTrip(auto: Bool = false) {
        guard isAuthorized else { return }
        // Идущую поездку второй старт НЕ перезапускает: trip.begin обнулил бы
        // километры, трек и проезды, накопленные до этого момента. Все
        // известные вызывающие проверяют isTripActive сами, но «ехал, выбрал
        // «Домой» — данные до этого пропали» (владелец, 11.10) означает, что
        // хотя бы один путь этого не делал. Теперь защита здесь, одна на всех.
        guard !isTripActive else {
            Log.trips.notice("startTrip при идущей поездке — игнорирую (auto: \(auto, privacy: .public))")
            return
        }
        refreshFamiliarCameras()   // «свои» камеры считаем один раз на поездку
        if auto, isPassengerSession { return }   // пассажир уже сказал своё слово
        // Режим «Умный»: сама поездка стартует только в знакомой машине, иначе
        // ждём подтверждения — но вопрос всё равно задаём (ниже), чтобы человек
        // мог включить оповещения одним тапом с локскрина.
        if auto, settings.tripStartMode == .smart, !isDriverRecognized {
            // Четвёртый исход «поездки нет»: она и не начиналась. Машина
            // незнакомая, режим «умный», вопрос задан — но если на него не
            // ответить, записи не будет вовсе, и без журнала это неотличимо
            // от потери (docs/plan_drive_complaints.md, Ж4).
            Log.trips.notice("автостарт отклонён: режим «умный», машина незнакомая — ждём ответа «вы за рулём?»")
            trip.noteDropped("notDriver")
            notifier.askDriverCheck()
            return
        }
        if !auto { isPassengerSession = false }  // ручной старт — точно за рулём
        isTripActive = true
        onTripStateChanged?(true)
        // Человек в машине — точка парковки больше не нужна (и при склейке).
        forgetParkedCar()
        lastDrivenFix = nil
        lastMovementAt = Date()   // не проваливаться в тир «стоянка» со старым штампом
        // Телефон в держателе — экран не гаснет всю поездку (как у навигаторов).
        // Кроме поездки за рулём CarPlay: там телефон показывает экран передачи,
        // и прибитый экран сводил бы «телефон отдыхает и не греется» к нулю.
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn && !isCarPlayConnected
        alertEngine.reset()
        passTracking.reset()
        alertRecall.reset()
        locationFilter.reset()
        speedSmoother.reset()
        roadSnapper.reset()
        voicedInGroup.removeAll()
        voicedHotspots.removeAll()
        postponedVoice = nil
        // Заезд по пути — не новая поездка: если пауза похожа на «забежал в
        // магазин», поднимаем прошлую запись обратно в живую сессию.
        // Заряд читаем один раз здесь: дельта за поездку — это видимая цена
        // приложения, ради которой приборка и строилась.
        let batteryPercent = BatteryProbe.percent()
        if !resumePreviousTripIfMerged(batteryPercent: batteryPercent) {
            trip.begin(batteryPercent: batteryPercent)
        }
        applyLocationMode()
        liveActivity?.startIfNeeded(state: activityState)
        if auto, !isDriverRecognized { notifier.askDriverCheck() }
    }

    /// Продолжить прошлую поездку вместо новой. Решение принимает чистый
    /// TripMerge; здесь только собираем факты. true — склеили.
    func resumePreviousTripIfMerged(batteryPercent: Int? = nil) -> Bool {
        guard let previous = trip.history.first,
              let previousEnd = previous.endCoordinate else { return false }
        let now = Date()
        // Пока GPS не дал первую точку, берём точку финиша прошлой поездки:
        // автостарт срабатывает раньше первого фикса, и иначе склейка не
        // случилась бы никогда именно в самом частом сценарии.
        let here = currentCoordinate ?? previousEnd
        // Езда началась раньше старта (поздний автостарт): стоянка кончилась
        // тогда, а не сейчас, и уехать машина успела дальше (S19).
        let paused = max(0, now.timeIntervalSince(previous.endedAt))
        let lateStart = min(paused, motion?.drivingSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
        let context = TripMerge.Context(
            stopDuration: paused - lateStart,
            metersFromPreviousEnd: GeoMath.fastDistance(here.latitude, here.longitude,
                                                        previousEnd.latitude,
                                                        previousEnd.longitude),
            endedManually: previous.endedManually ?? false,
            stopNearSavedPlace: TripMerge.isNearSavedPlace(previousEnd, places: savedPlaces),
            crossesDay: !Calendar.current.isDate(previous.endedAt, inSameDayAs: now),
            existingStops: previous.stops?.count ?? 0,
            previousDuration: previous.duration,
            lateStartSeconds: lateStart)
        guard TripMerge.shouldMerge(context) else { return false }
        trip.resume(previous, stoppedUntil: now, batteryPercent: batteryPercent)
        return true
    }

    var savedPlaces: [CLLocationCoordinate2D] { settings.savedPlaceCoordinates }

    /// Своя машина: CarPlay подключён или знакомая автомобильная магнитола (BT).
    var isDriverRecognized: Bool {
        if isCarPlayConnected { return true }
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { output in
            output.portType == .carAudio
                || ((output.portType == .bluetoothA2DP || output.portType == .bluetoothHFP)
                    && settings.knownCarAudio.contains(output.portName))
        }
    }

    /// «Я за рулём» (кнопка или тап по вопросу): запоминаем магнитолу этой машины —
    /// в следующий раз не переспросим. В «Умном» режиме вопрос приходит ДО старта
    /// поездки (сама она в чужой машине не стартует) — подтверждение и есть старт.
    func confirmDriver() {
        notifier.clearDriverCheck()
        isPassengerSession = false
        for output in AVAudioSession.sharedInstance().currentRoute.outputs
        where output.portType == .bluetoothA2DP || output.portType == .bluetoothHFP {
            if !settings.knownCarAudio.contains(output.portName) {
                settings.knownCarAudio.append(output.portName)
            }
        }
        if !isTripActive { startTrip() }
    }

    /// «Я пассажир»: свернуть поездку без следа в истории и молчать до конца езды.
    func markPassenger() {
        notifier.clearDriverCheck()
        isPassengerSession = true
        if isTripActive { endTrip(asPassenger: true) }
    }

    /// Езда закончилась (CoreMotion): следующая поездка — с чистого листа.
    func endPassengerSession() {
        isPassengerSession = false
    }

    /// Завершить поездку: сохранить итоги и вернуться к батареесберегающему фону.
    /// `asPassenger` — «я в такси»: короткий кусок не пишем в историю вовсе.
    /// `auto` — автостоп по CoreMotion (а не кнопка): только такую поездку можно
    /// потом продолжить как заезд по пути.
    func endTrip(asPassenger: Bool = false, auto: Bool = false) {
        isTripActive = false
        onTripStateChanged?(false)
        UIApplication.shared.isIdleTimerDisabled = false
        // Всю поездку геозоны не перерегистрировались (retile их пропускает —
        // сработать они всё равно не могли). Возвращаясь в тихий фон, ставим
        // их вокруг места парковки, а не города въезда.
        if let coordinate = currentCoordinate { retile(around: coordinate) }
        alertEngine.reset()
        // Итог работы предупреждений за поездку — до сброса счётчиков.
        // Пассажирская поездка тоже считается: камеры мимо ехали настоящие,
        // и промах конвейера от того, кто за рулём, не зависит.
        let recall = alertRecall.tally()
        if !recall.isEmpty { onAlertRecall?(recall) }
        // Камеры, мимо которых ещё «проезжали» в момент остановки, — ДО сброса
        // счётчика: записи проезда нужно знать, предупреждали ли о камере.
        // После сброса каждый такой проезд выходил «промолчала» — и камера,
        // о которой сказали за 300 м до парковки, звала жаловаться (ревью 19.10).
        let tailPasses = passTracking.flush()
        if !asPassenger { register(passes: tailPasses) }   // пассажирские не считаем
        alertRecall.reset()
        voicedInGroup.removeAll()
        postponedVoice = nil
        notifier.clearDriverCheck()   // вопрос «вы за рулём?» больше не актуален
        let batteryPercent = BatteryProbe.percent()
        if asPassenger {
            trip.discardAsPassenger()
        } else {
            trip.finish(endedManually: !auto, batteryPercent: batteryPercent)
            parkCar()
            // Автостоп с телефоном в кармане: короткие итоги на локскрин —
            // цифры дошли до человека, даже если он не откроет приложение.
            // Свежесть по endedAt, а не по новому id: у продолженной поездки
            // (склейка) id остаётся старым.
            if auto, !isPhoneForeground, let record = trip.history.first,
               Date().timeIntervalSince(record.endedAt) < 30 {
                notifier.notifyTripSummary(tripID: record.id, distance: record.distanceMeters,
                                           rating: record.score.map { Int($0) },
                                           fineRisk: TripHistory.fineRisk(of: record.passed))
            }
            // Припарковались у цели — маршрут выполнен, линия не должна висеть на карте.
            route?.finishIfNearDestination(coordinate: currentCoordinate)
        }
        // «Стоп» рукой — конец и маршрута (NavigationFlow): иначе стоп на
        // одном экране оставлял ведение на другом (12.10, машина вела после
        // «Поездка завершена»). Автостоп и «я пассажир» маршрут оставляют.
        let end: NavigationFlow.TripEnd = asPassenger ? .passenger : (auto ? .auto : .manual)
        if !NavigationFlow.keepsRoute(after: end), let route, route.isActive {
            route.clear()
        }
        applyLocationMode()
        liveActivity?.end()
        notifier.clearApproaching()   // конец поездки — убрать висящий баннер камеры
        // Часы сразу в «ожидание», не дожидаясь следующего GPS-тика.
        watchBridge?.update(isTripActive: false, speedKmh: 0, cameraTitle: nil, cameraSymbol: nil,
                            distanceMeters: nil, alertLevel: 0, limitKmh: nil, isOverspeeding: false)
    }

    func register(passes: [PassTracking.Pass]) {
        // Пишутся проезды камер, которые меряют скорость (не «Пост», не «ДТП»),
        // и не неподтверждённых отметок: подброшенная фальшивка на проспекте
        // стоила бы баллов и «штрафа» каждому, кто мимо проехал (ревью S6).
        for pass in passes where pass.camera.kind.recordsPasses && !pass.camera.isUnconfirmedMobile {
            guard trip.registerPass(camera: pass.camera, speedKmh: pass.speedKmh,
                                    limitKmh: pass.limitKmh, roadLimitKmh: pass.roadLimitKmh,
                                    limitAssumed: pass.limitAssumed,
                                    courseDegrees: pass.courseDegrees,
                                    speedAfterKmh: pass.speedAfterKmh,
                                    silent: !alertRecall.wasAlerted(cameraID: pass.camera.id),
                                    date: pass.date) else { continue }
            onPassRecorded?(pass.limitKmh == nil ? "none"
                            : (pass.limitAssumed ? "assumed" : "tag"))
        }
    }
}
