//
//  LocationService+Modes.swift
//  RadarMap
//
//  Режимы геолокации: передний план, CarPlay, точность GPS по ступеням, ожидание координаты.
//

import Foundation
import AVFAudio
import CoreLocation
import Observation
import os
import UIKit

extension LocationService {

    // MARK: - Режимы геолокации

    /// Координата, от которой можно СТРОИТЬ: грубая не годится.
    ///
    /// `currentCoordinate` заполняется из двух мест. Одно — живой
    /// отфильтрованный фикс. Другое — `seedContext`, грубая точка режима
    /// значимых перемещений; её собственный комментарий гласит, что после неё
    /// расстояние на панели не живое, и рядом выставляется `isPositionCoarse`.
    ///
    /// Маршрут этого флага не проверял и мог быть посчитан от точки за
    /// километры — он выглядит настоящим и ведёт не туда. Здесь мы ждём именно
    /// живой фикс, а не отдаём первый попавшийся, и честно возвращаем `nil`,
    /// если он не пришёл: не построить лучше, чем построить от вчерашнего
    /// места (plan_drive_complaints.md, Ж5).
    func awaitPreciseCoordinate(timeout: TimeInterval = 6) async -> CLLocationCoordinate2D? {
        await awaitPosition(timeout: timeout, precise: true)
    }

    /// Курс, с которым строить маршрут от точки выше (20.9): только на ходу и
    /// с достоверным курсом (`RouteService.requestHeading`), иначе nil.
    /// Первый маршрут на ходу без курса OSRM начинал куда ему короче — часто
    /// с разворота за спиной машины. Скорость без фиксов гаснет сама
    /// (`armSpeedDecay`), так что курс пропавшего сигнала сюда не доживёт.
    var routeHeading: CLLocationDirection? {
        RouteService.requestHeading(course: currentCourse, speedKmh: speedKmh)
    }

    /// Координата для интентов (холодный старт из Siri: bootstrap не выполнялся,
    /// currentCoordinate пуст) — просим одноразовый фикс и ждём его до `timeout`.
    func awaitCoordinate(timeout: TimeInterval = 5) async -> CLLocationCoordinate2D? {
        await awaitPosition(timeout: timeout, precise: false)
    }

    /// Одноразовый фикс и ожидание его до `timeout` — общий цикл обеих
    /// просьб выше. `precise` — грубая точка (фоновый режим) не годится:
    /// маршрут от неё начинается за километры.
    func awaitPosition(timeout: TimeInterval, precise: Bool) async -> CLLocationCoordinate2D? {
        func ready() -> CLLocationCoordinate2D? {
            precise && isPositionCoarse ? nil : currentCoordinate
        }
        if let point = ready() { return point }
        guard isAuthorized else { return nil }
        manager.requestLocation()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let point = ready() { return point }
            await Task.pause(seconds: AppConfig.positionWaitStepSeconds)
        }
        return ready()
    }

    /// Телефонная сцена открыта/свёрнута. Точный GPS для HUD держим, только пока открыто и НЕ в поездке.
    func setForeground(_ foreground: Bool) {
        isPhoneForeground = foreground
        // Открыли приложение — «камерный» баннер из фона больше не нужен (внутри есть свой алерт).
        if foreground { notifier.clearApproaching() }
        applyLocationMode()
        // Вернулись в приложение — пересчитать по последней известной точке, не
        // дожидаясь фикса: стоящий телефон может не дать его ещё долго.
        if foreground, let coordinate = currentCoordinate {
            recomputeNearest(from: coordinate)
        }
        // Поездка, начатая в фоне (автостарт по CoreMotion в кармане), Live
        // Activity не получала вовсе: ActivityKit не даёт запрашивать её из
        // фона, а повторной попытки не было — водитель открывал приложение и
        // не находил на локскрине ничего. Метод идемпотентен (guard activity
        // == nil), поэтому одна попытка на поездку, не чаще.
        if foreground, isTripActive {
            liveActivity?.startIfNeeded(state: activityState)
        } else if foreground, liveActivity?.isActive == true {
            // Открыли приложение, а поездки нет: плашка — сирота прошлого
            // процесса (его убили посреди поездки) — снять (S14).
            liveActivity?.end()
        }
    }

    /// Экран в машине подключён/отключён — самостоятельный «передний план»,
    /// не зависящий от того, заблокирован ли телефон в кармане.
    func setCarPlayConnected(_ connected: Bool) {
        isCarPlayConnected = connected
        applyLocationMode()
        // Отключили у цели — заглушили машину: поездка закроется (ArrivalFinish).
        if !connected { noteCarPlayDisconnectedForArrival() }
    }

    /// Настройки сменили GPS-политику (например, тумблер адаптивности) — применить сразу,
    /// не дожидаясь следующей смены состояния поездки.
    func refreshLocationMode() {
        applyLocationMode()
    }

    /// Единая точка выбора режима GPS исходя из (поездка, открыто ли приложение, энергосбережение).
    func applyLocationMode() {
        guard isAuthorized else { return }
        accuracyTier = -1   // режим сменился — адаптивная точность переоценится на след. тике
        guard isTripActive || isForeground else {
            // Тихий фон: непрерывный GPS выключен, работают SLC + геозоны (будят на уведомление).
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
            manager.pausesLocationUpdatesAutomatically = true
            isSignalStale = false   // без непрерывного GPS «нет сигнала» не про нас
            locationFilter.reset()
            speedSmoother.reset()
            roadSnapper.reset()
            standstill.reset()
            frozenDisplay = nil
            displayCoordinate = nil
            displayCourse = -1
            markerMotion = nil
            // Вернулись в тихий фон — геозоны снова единственный способ узнать
            // о камере, и ставить их надо вокруг того места, где мы сейчас.
            // Пока шёл непрерывный GPS, retile их не трогал (см. там), так что
            // без этой строки они остались бы вокруг точки, где экран открыли.
            // Ровно один раз на переход: applyLocationMode зовётся и от смены
            // энергосбережения, и из настроек, а перевзводить двадцать геозон
            // на каждый такой вызов — та же трата, от которой мы и уходим.
            if !geofencesArmed, let coordinate = currentCoordinate {
                retile(around: coordinate)
            }
            return
        }
        // Паузу отдавать системе нельзя ни в поездке, ни в машине: iOS ставит
        // поток фиксов на паузу сама и сама его НЕ возобновляет. В поездке это
        // знали и запрещали давно; на CarPlay запрет забыли — и экран машины
        // замирал на нуле, потому что телефон лежит в держателе неподвижно
        // относительно себя, а система считает это «пользователь остановился».
        manager.pausesLocationUpdatesAutomatically = !(isTripActive || isCarPlayConnected)
        if isTripActive || isCarPlayConnected {
            // Поездка: высокая точность, разрешаем работу в фоне (с «Всегда» —
            // всегда, с «При использовании» — если начата на экране). Экран
            // машины без начатой поездки — это тоже вождение:
            // цифры на нём обязаны быть живыми, а телефон при этом обычно
            // заблокирован в держателе, и без флага фона система вправе
            // перестать слать фиксы. Дальше точность ведёт лестница
            // (tuneAdaptiveAccuracy).
            manager.desiredAccuracy = isLowPowerMode ? kCLLocationAccuracyNearestTenMeters : kCLLocationAccuracyBest
            manager.distanceFilter = isLowPowerMode ? 20 : 5
            // И при «При использовании»: поездка, начатая на экране, вправе
            // жить в фоне (iOS показывает синий индикатор). До 20.10 флаг
            // ставился только для «Всегда», и поездка с «При использовании»
            // молчала, стоило заблокировать телефон или открыть Яндекс
            // (сценарий S2). Автостарт и геозоны «Всегда» по-прежнему требуют.
            manager.allowsBackgroundLocationUpdates =
                [.authorizedAlways, .authorizedWhenInUse].contains(manager.authorizationStatus)
            manager.showsBackgroundLocationIndicator = true
        } else {
            // Просто открытое приложение: точный GPS для HUD, фон не держим.
            // Точность — как у Apple Карт (почему — GPSTiers.foreground).
            let request = GPSTiers.foreground(lowPower: isLowPowerMode)
            foregroundIdle = false
            manager.desiredAccuracy = request.accuracy
            manager.distanceFilter = request.distanceFilter
            manager.allowsBackgroundLocationUpdates = false
            manager.showsBackgroundLocationIndicator = false
        }
        manager.startUpdatingLocation()
        armColdStartWatchdog()
    }

    /// Сторож холодного старта непрерывного GPS.
    ///
    /// Обычный сторож (armStaleWatchdog) взводится только из ПРИНЯТОЙ ветки
    /// фикса и только в движении — то есть с крытого паркинга, где первый фикс
    /// не приходит или бракуется, «Нет сигнала» не зажигалось никогда: док
    /// уверенно показывал «Чисто» и 0 км/ч, схема — «появится в движении»,
    /// и вся эта тишина была неотличима от сломанного приложения. Здесь окно
    /// щедрое (staleWatchdogMaxSeconds): первому фиксу позволено идти долго,
    /// но не бесконечно. Принятый фикс гасит флаг обычным путём, а стоянка с
    /// живым фиксом отменяет этого сторожа через armStaleWatchdog.
    func armColdStartWatchdog() {
        // Позиция свежая — сторожу нечего сторожить, обычный цикл уже идёт.
        if let accepted = lastAcceptedAt,
           Date().timeIntervalSince(accepted) < AppConfig.gpsStaleSeconds { return }
        fixSequence &+= 1
        staleWatchdogTask?.cancel()
        let sequence = fixSequence
        staleWatchdogTask = Task { [weak self] in
            // Ошибка sleep — только отмена задачи; что делать после неё, решает проверка ниже.
            try? await Task.sleep(for: .seconds(AppConfig.staleWatchdogMaxSeconds))
            guard !Task.isCancelled, let self, self.fixSequence == sequence,
                  self.isTripActive || self.isForeground else { return }
            self.isSignalStale = true
            Log.location.notice("непрерывный GPS запущен, но принятых фиксов нет — сигнал потерян")
        }
    }

    /// Адаптивный GPS в поездке: максимум только в ФИНАЛЬНОМ подходе к камере/манёвру,
    /// где важен точный отсчёт и учёт проезда. На крейсере — 10 м и больший distanceFilter:
    /// GPS-чип работает мягче И весь пайплайн (+ следование карты) тикает реже — меньше нагрев.
    /// В плотном городе, где камера почти всегда «где-то рядом», это ключевая экономия:
    /// бинарный порог 3 км там не срабатывал и точность держалась на максимуме весь путь.
    func tuneAdaptiveAccuracy() {
        // Энергосбережение больше не отменяет лестницу: оно запрещает верхнюю
        // ступень, но оставляет нижние. Раньше стояла отмена целиком, и на
        // стоянке в этом режиме чип работал ВДВОЕ точнее, чем без него.
        // CarPlay без поездки — тоже вождение с живыми оповещениями, и лестница
        // ему положена: раньше он держал «Best» и фильтр 5 м всю сессию, в том
        // числе на стоянке и на трассе вдали от камер (аудит 11.10).
        if !(isTripActive || isCarPlayConnected) { return tuneForegroundAccuracy() }
        guard settings.adaptiveGPS else { return }
        let cameraDistance = distanceToNearest ?? .greatestFiniteMagnitude
        let stepDistance = (route?.isActive == true && route?.nextStep != nil)
            ? (route?.nextStepDistance ?? .greatestFiniteMagnitude)
            : .greatestFiniteMagnitude
        let nearest = min(cameraDistance, stepDistance)

        // Порядок правил (стоянка бьёт близость вне 150 м) — в чистом
        // GPSTiers под тестами.
        let tier = GPSTiers.tier(.init(
            nearestTargetMeters: nearest,
            speedKmh: speedKmh,
            idleSeconds: Date().timeIntervalSince(lastMovementAt)),
                                 lowPower: isLowPowerMode)
        // На карту смотрят (машина или открытый телефон) — фиксы без фильтра
        // расстояния: спидометр и камера карты живут каждую секунду.
        let watched = isForeground
        guard tier != accuracyTier || watched != accuracyWatched else { return }
        accuracyTier = tier
        accuracyWatched = watched
        let request = GPSTiers.request(tier: tier, watched: watched)
        manager.desiredAccuracy = request.accuracy
        manager.distanceFilter = request.distanceFilter
    }

    /// Открытый экран без поездки: телефон лежит — чип на «до 10 м», тронулись
    /// — снова «Best» (GPSTiers.foreground). Только на принятых фиксах.
    func tuneForegroundAccuracy() {
        guard isForeground else { return }
        var idle = settings.adaptiveGPS
            && GPSTiers.foregroundIdle(idleSeconds: Date().timeIntervalSince(lastMovementAt),
                                       hasPosition: currentCoordinate != nil,
                                       nearestCameraMeters: distanceToNearest ?? .infinity)
        // Сдвинулись от места, где легли, — уже не лежим, даже если первый
        // фикс после фильтра 30 м ещё показал «0 км/ч».
        if foregroundIdle, let anchor = idleAnchor, let here = currentCoordinate,
           GeoMath.fastDistance(anchor.latitude, anchor.longitude, here.latitude, here.longitude)
            >= AppConfig.gpsIdleLeaveMeters {
            idle = false
            lastMovementAt = Date()
        }
        guard idle != foregroundIdle else { return }
        foregroundIdle = idle
        idleAnchor = idle ? currentCoordinate : nil
        let request = GPSTiers.foreground(lowPower: isLowPowerMode, idle: idle)
        manager.desiredAccuracy = request.accuracy
        manager.distanceFilter = request.distanceFilter
        Log.location.info("открытый экран: \(idle ? "лежит — точность до 10 м" : "движение — точность максимум", privacy: .public)")
    }

    /// Попросить точную геопозицию на эту сессию (если дана «приблизительная»).
    func requestPreciseLocation() {
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "CameraAlerts")
    }

    /// Пересобрать мониторинг вокруг текущей позиции (после добавления/скрытия
    /// камеры, догрузки базы или смены радиуса).
    ///
    /// `evaluateNow` — «оповести немедленно, не жди следующего фикса». Нужен
    /// приезду чужой отметки: движок оповещений живёт внутри обработчика
    /// локации, и без этого флага водитель узнавал о радаре впереди только со
    /// следующим фиксом, попавшим в ретайл. Внутри всё идемпотентно
    /// (`alertEngine.evaluate` помнит уровень по камере), лишний вызов не
    /// добавляет ни фразы, ни писка.
    func refreshMonitoring(evaluateNow: Bool = false) {
        anchor = nil
        // Без доступа — замороженная позиция: окно камер и оповещения по ней
        // не пересчитываем (ближайшая снята, и снята насовсем).
        guard let coordinate = currentCoordinate, isAuthorized else { return }
        retile(around: coordinate)
        // Пересчёт ближайшей обязателен, а не «до следующего фикса»: база
        // догружается асинхронно и часто уже ПОСЛЕ первого фикса, а на стоящем
        // телефоне следующий фикс может не прийти вовсе (distanceFilter). Панель
        // тогда навсегда оставалась с «камер рядом нет», хотя камеры на карте
        // видны — она читает базу напрямую, а оповещения ждали окна.
        recomputeNearest(from: coordinate)
        recomputeDirection()
        // Тот же гейт, что и в обработчике локации: активное оповещение — это
        // поездка или открытый экран. В тихом фоне о камере говорят геозоны.
        if evaluateNow, isTripActive || isForeground { runAlertEngine() }
    }
}
