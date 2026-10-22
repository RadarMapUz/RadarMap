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
    /// `byCarLink` — старт от подключения к своей машине (CarLink): отключение
    /// её и закончит.
    func startTrip(auto: Bool = false, byCarLink: Bool = false) {
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
        guard auto else {
            refreshFamiliarCameras()   // «свои» камеры считаем один раз на поездку
            return beginTrip(auto: false, byCarLink: byCarLink, askAfterStart: false)
        }
        // Старт от CoreMotion: «своя ли машина» решают выходы аудио, а
        // `currentRoute` — поход к mediaserverd. Читаем его вне главного
        // потока (правило 21; отчёт качества 22.10, п. 6) и решаем по свежему
        // снимку — тому же, что читался здесь синхронно: кэш CarLinkService
        // в приостановленном процессе мог пропустить подключение магнитолы.
        autoStartRead &+= 1
        let generation = autoStartRead
        Task { [weak self] in
            let ports = await CarLinkService.readPorts()
            // Поколение (правило 12): решает только последнее чтение.
            guard let self, generation == self.autoStartRead else { return }
            self.decideAutoStart(ports: ports, byCarLink: byCarLink)
        }
    }

    /// Автостарт по движению с прочитанными портами аудио.
    private func decideAutoStart(ports: [CarLink.Port], byCarLink: Bool) {
        // За время чтения поездку могли начать (кнопка, машина) — не трогаем.
        guard isAuthorized, !isTripActive else { return }
        refreshFamiliarCameras()   // «свои» камеры считаем один раз на поездку
        // Старт от CoreMotion: писать молча, писать и спросить, только
        // спросить или ничего — решает чистый CarLink.autoStart (26.3).
        var askAfterStart = false
        switch CarLink.autoStart(mode: settings.tripStartMode,
                                 recognized: isDriverRecognized(ports: ports),
                                 passenger: isPassengerSession,
                                 ownCarConfigured: !settings.carDevices.isEmpty) {
        case .ignore:
            return   // пассажир уже сказал своё слово, или режим не от движения
        case .askOnly:
            // Четвёртый исход «поездки нет»: она и не начиналась. Машина
            // незнакомая («Умный»; «Авто», когда своя машина выбрана в
            // настройках и её нет — такси), вопрос задан — но если на него
            // не ответить, записи не будет вовсе, и без журнала это
            // неотличимо от потери (docs/plan_drive_complaints.md, Ж4).
            Log.trips.notice("автостарт отклонён: машина не своя (\(self.settings.tripStartMode.rawValue, privacy: .public)) — ждём ответа «вы за рулём?»")
            trip.noteDropped("notDriver")
            notifier.askDriverCheck()
            return
        case .startAndAsk:
            askAfterStart = true
        case .start:
            break
        }
        beginTrip(auto: true, byCarLink: byCarLink, askAfterStart: askAfterStart)
    }

    /// Сам старт поездки — решение уже принято.
    private func beginTrip(auto: Bool, byCarLink: Bool, askAfterStart: Bool) {
        if !auto { isPassengerSession = false }  // ручной старт — точно за рулём
        tripFromCarLink = byCarLink || (carLinked?() ?? false)
        Log.trips.notice("поездка начата: \(byCarLink ? "машина подключена" : (auto ? "движение" : "вручную"), privacy: .public)")
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
        speedometer.restartSmoothing()
        roadSnapper.reset()
        voicedInGroup.removeAll()
        voicedHotspots.removeAll()
        voicedRoadEvents.removeAll()
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
        alerts.warmHaptics()   // асинхронно: первый сигнал поездки не ждёт движок
        if askAfterStart { notifier.askDriverCheck() }
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
            lateStartSeconds: lateStart,
            stopAtDestination: previous.endedAtDestination == true)
        guard TripMerge.shouldMerge(context) else { return false }
        trip.resume(previous, stoppedUntil: now, batteryPercent: batteryPercent)
        return true
    }

    var savedPlaces: [CLLocationCoordinate2D] { settings.savedPlaceCoordinates }

    /// Своя машина: CarPlay, выбранное в настройках устройство или знакомая
    /// по «Я за рулём» магнитола — но не наушники (CarLink.isRecognized, 26.3).
    /// Порты читает вызывающий — вне главного потока (`CarLinkService.readPorts`).
    func isDriverRecognized(ports: [CarLink.Port]) -> Bool {
        if isCarPlayConnected { return true }
        return CarLink.isRecognized(ports: ports, chosen: settings.carDevices, known: settings.knownCarAudio)
    }

    /// «Я за рулём» (кнопка или тап по вопросу): запоминаем магнитолу этой машины —
    /// в следующий раз не переспросим. В «Умном» режиме вопрос приходит ДО старта
    /// поездки (сама она в чужой машине не стартует) — подтверждение и есть старт.
    func confirmDriver() {
        notifier.clearDriverCheck()
        isPassengerSession = false
        // Ручной старт магнитолу не спрашивает — поездка сразу, а имена
        // выходов аудио дочитываются вне главного потока (правило 21).
        if !isTripActive { startTrip() }
        Task { [weak self] in
            let names = await Self.carAudioNames()
            guard let self else { return }
            for name in names where !self.settings.knownCarAudio.contains(name) {
                self.settings.knownCarAudio.append(name)
            }
        }
    }

    /// Bluetooth-выходы аудио сейчас — кандидаты в «знакомую магнитолу».
    /// Наушники не запоминаем: «Я за рулём» в AirPods делало каждое такси
    /// в тех же AirPods «своей машиной» — поездка писалась молча (26.3).
    @concurrent
    nonisolated static func carAudioNames() async -> [String] {
        AVAudioSession.sharedInstance().currentRoute.outputs
            .filter { ($0.portType == .bluetoothA2DP || $0.portType == .bluetoothHFP)
                && !CarLink.looksLikeHeadphones($0.portName) }
            .map(\.portName)
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
    /// `auto` — автостоп по CoreMotion или у цели (а не кнопка): только такую
    /// поездку можно потом продолжить как заезд по пути.
    /// `atDestination` — закрыло прибытие к цели маршрута (ArrivalFinish).
    func endTrip(asPassenger: Bool = false, auto: Bool = false, atDestination: Bool = false) {
        stopArrivalWatch()   // любой конец поездки — следить за прибытием незачем
        isTripActive = false
        tripFromCarLink = false
        lastTripEnd = (asPassenger ? .passenger : (auto ? .auto : .manual), atDestination)
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
        // Номера камер, а не координаты: база публичная, а маршрут по ним
        // восстановить нельзя — промахи и лишние предупреждения названы поштучно.
        Log.alerts.notice("охват поездки: проехали \(recall.passed, privacy: .public), вовремя \(recall.warned, privacy: .public), поздно \(recall.late, privacy: .public), молча \(self.alertRecall.silentIDs, privacy: .public), не наши (доказано) \(self.alertRecall.notOursIDs, privacy: .public), впустую \(self.alertRecall.unusedIDs, privacy: .public)")
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
            trip.finish(endedManually: !auto, batteryPercent: batteryPercent,
                        work: settings.workDriverMode, atDestination: atDestination)
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
        if !NavigationFlow.keepsRoute(after: lastTripEnd.kind), let route, route.isActive {
            route.clear()
        }
        applyLocationMode()
        liveActivity?.end()
        notifier.clearApproaching()   // конец поездки — убрать висящий баннер камеры
        // Часы сразу в «ожидание», не дожидаясь следующего GPS-тика.
        watchBridge?.update(isTripActive: false, speedKmh: 0, cameraTitle: nil, cameraSymbol: nil,
                            cameraID: nil, distanceMeters: nil, alertLevel: 0, limitKmh: nil,
                            isOverspeeding: false)
    }

    func register(passes: [PassTracking.Pass]) {
        // Пишутся проезды камер, которые меряют скорость (не «Пост», не «ДТП»),
        // и не неподтверждённых отметок: подброшенная фальшивка на проспекте
        // стоила бы баллов и «штрафа» каждому, кто мимо проехал (ревью S6).
        for pass in passes where pass.camera.kind.recordsPasses && !pass.camera.isUnconfirmedMobile {
            Log.trips.notice("проезд камеры \(pass.camera.id, privacy: .public): \(Int(pass.speedKmh), privacy: .public) км/ч, лимит \(pass.limitKmh ?? 0, privacy: .public), предупреждали \(self.alertRecall.wasAlerted(cameraID: pass.camera.id), privacy: .public)")
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
