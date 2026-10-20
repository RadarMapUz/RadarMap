//
//  LocationService+Fix.swift
//  RadarMap
//
//  Фикс GPS: фильтр, сторожа сигнала и скорости, стоянка, тело тика (handleLocationBody), разрешения.
//

import Foundation
import AVFAudio
import CoreLocation
import Observation
import os
import UIKit

extension LocationService {

    func refreshCruise() {
        #if canImport(MapLibre)
        let maneuver = route?.isActive == true && route?.nextStep != nil ? route?.nextStepDistance : nil
        let next = EngineMapView.Coordinator.isCruise(was: isCruising, tripActive: isTripActive,
                                                      speedKmh: speedKmh,
                                                      approachingCamera: isApproachingCamera,
                                                      maneuverMeters: maneuver)
        if next != isCruising { isCruising = next }
        #endif
    }

    func handleFix(_ fix: LocationFilter.Fix) {
        switch locationFilter.accept(fix) {
        case .rejected(let reason):
            Log.location.debug("фикс отброшен: \(reason.rawValue, privacy: .public), точность \(fix.horizontalAccuracy, privacy: .public) м")
            // Фикс не годится для алертов, проездов и трека — на этом и построен
            // гейт. Но для карты и списка «рядом» он лучше устаревшей точки:
            // район тот же. Раньше так подхватывался только САМЫЙ первый
            // кэшированный фикс; если следующие тоже отбрасывались (в помещении
            // точность легко 70–100 м), панель до конца сессии уверенно
            // показывала расстояние от места, где телефон был в прошлый раз —
            // посреди Ташкента это выглядело как «10.4 км до камеры».
            // Перелёт (jump) не берём: это заведомо мусорная координата.
            let positionIsOld = currentCoordinate == nil
                || Date().timeIntervalSince(lastAcceptedAt ?? .distantPast) > AppConfig.gpsStaleSeconds
            // В поездке — тоже. Условие «!isTripActive» здесь выключало
            // единственный запасной путь обновления позиции ровно тогда, когда
            // водитель за рулём: телефон глубоко под стеклом или городской
            // каньон бракует КАЖДЫЙ фикс по точности, и весь экран машины
            // (док, схема, лента) замирал без единого честного слова. Грубая
            // точка идёт только в картинку с флагом isPositionCoarse
            // («Уточняем положение»); алерты, проезды и трек живут строго на
            // принятых фиксах — seedContext их не трогает.
            if reason != .jump, fix.horizontalAccuracy > 0, positionIsOld {
                seedContext(from: CLLocationCoordinate2D(latitude: fix.lat,
                                                         longitude: fix.lon))
            }
            // Замок стоянки. Тир 3 просит у системы точность 100 м, а фильтр
            // пропускает не хуже 65 м. Тир пересматривается только на ПРИНЯТОМ
            // фиксе — и если система отдаёт сотовые 100–300 м (трасса, вышки
            // вместо Wi-Fi), каждый фикс отбрасывается, тир не поднимается
            // никогда, и машина уезжает со стоянки с молчащими оповещениями.
            // Молчание о камере хуже лишнего расхода батареи: забракован по
            // точности на стоянке в поездке — сразу поднимаем точность до
            // верхней ступени; следующий принятый фикс выставит тир по правилам.
            if reason == .accuracy, isTripActive || isCarPlayConnected, accuracyTier == 3 {
                Log.location.notice("стоянка: фикс \(fix.horizontalAccuracy, privacy: .public) м отброшен — поднимаем точность")
                accuracyTier = 0
                let request = GPSTiers.request(tier: 0, watched: isForeground)
                manager.desiredAccuracy = request.accuracy
                manager.distanceFilter = request.distanceFilter
            }
            // То же для открытого экрана без поездки: забракован по точности —
            // просим максимум, иначе метка так и стоит по грубой точке.
            // Телефон лежит, точка уже есть — грубый фикс в помещении не повод
            // будить чип: иначе лежачая точность и подъём сменяли бы друг друга.
            if reason == .accuracy, !isTripActive, isForeground, !foregroundIdle,
               let raised = GPSTiers.escalatedAccuracy(from: manager.desiredAccuracy) {
                Log.location.notice("открытый экран: фикс \(fix.horizontalAccuracy, privacy: .public) м отброшен — поднимаем точность")
                manager.desiredAccuracy = raised
            }
        case .accepted(let good):
            if isSignalStale { isSignalStale = false }
            if isPositionCoarse { isPositionCoarse = false }
            lastAcceptedAt = Date()
            // Время точки трека — время ФИКСА: после фоновой паузы iOS отдаёт
            // фиксы пачкой, и часы обработки дали бы им одно время.
            lastFixTime = min(fix.timestamp, Date())
            horizontalAccuracy = good.accuracy
            isFixSimulated = fix.isSimulated
            handleLocation(coordinate: CLLocationCoordinate2D(latitude: good.lat,
                                                              longitude: good.lon),
                           speed: good.speed ?? -1, course: good.course)
            armStaleWatchdog()
            armSpeedDecay()
        }
    }

    /// Окрестности по грубой точке: камеры вокруг и ближайшая для HUD.
    /// Ни алертов, ни трека, ни зачёта проездов — только контекст на экране.
    /// Флаг `isPositionCoarse` обязателен: расстояние на панели после этого не
    /// живое, и выдавать его за живое было бы обманом.
    func seedContext(from coordinate: CLLocationCoordinate2D) {
        currentCoordinate = coordinate
        isPositionCoarse = true
        retileIfNeeded(around: coordinate)
        recomputeNearest(from: coordinate)
        // Тик двигаем и здесь: схема и лента CarPlay подписаны на него, а не
        // на координату — без тика они стояли на прошлой точке, пока док уже
        // честно показывал «Уточняем положение» по новой.
        locationTick &+= 1
    }

    /// Сторож потери сигнала: перезаряжается на каждом принятом фиксе, поэтому
    /// срабатывает только если новых фиксов действительно не пришло.
    ///
    /// Отменяемая Task, а не asyncAfter: тот отменить нельзя, и каждый его
    /// блок ВСЁ РАВНО просыпался в свой дедлайн — при фиксе раз в 1.5 с и окне
    /// 8 с это 5–6 висящих таймеров и лишнее пробуждение main на каждый фикс
    /// всю поездку. Отмена Task будит его один раз сразу (в текущей работе),
    /// а не по будильнику в будущем.
    ///
    /// Заряжается ТОЛЬКО в движении и с окном по ожидаемому интервалу фиксов:
    /// на стоянке и в пробке фиксы не приходят из-за distanceFilter, а не из-за
    /// спутников, и «нет сигнала» было бы прямой ложью водителю.
    func armStaleWatchdog() {
        fixSequence &+= 1   // прошлый сторож обесценен даже если новый не ставим
        staleWatchdogTask?.cancel()
        guard Self.watchdogArms(speedKmh: speedKmh, distanceFilter: manager.distanceFilter) else { return }
        // Заряжен только из-за «фильтра нет» (иначе на этой скорости он бы
        // не встал): если к сроку фильтр появился (ушли с экрана, машина
        // отключилась) — стоим и молчим из-за фильтра, «нет сигнала» — ложь.
        let armedWithoutFilter = speedKmh < AppConfig.staleWatchdogMinSpeedKmh
        let speedMps = speedKmh / 3.6
        let expected = manager.distanceFilter <= 0 ? 1
            : (speedMps > 0 ? manager.distanceFilter / speedMps : .infinity)
        let window = max(AppConfig.gpsStaleSeconds,
                         min(AppConfig.staleWatchdogMaxSeconds,
                             expected * AppConfig.staleWatchdogSlack))
        let sequence = fixSequence
        staleWatchdogTask = Task { [weak self] in
            // Ошибка sleep — только отмена задачи; что делать после неё, решает проверка ниже.
            try? await Task.sleep(for: .seconds(window))
            guard !Task.isCancelled, let self, self.fixSequence == sequence,
                  self.isTripActive || self.isForeground else { return }
            if armedWithoutFilter, self.manager.distanceFilter > 0 { return }
            // Стоим (CoreMotion уверен) — фиксов нет из-за distanceFilter,
            // а не из-за спутников: «нет сигнала» у светофора — ложь.
            if self.motion?.isStationary == true {
                Log.location.debug("фиксов нет, но телефон стоит — сигнал не потерян")
                return
            }
            self.isSignalStale = true
            Log.location.notice("нет фиксов \(window, format: .fixed(precision: 1), privacy: .public) с — сигнал потерян")
        }
    }

    /// Сторож «нет сигнала» заряжается в движении — или при любой скорости,
    /// когда фильтра расстояния нет (экран открыт, CarPlay): тогда фиксы идут
    /// раз в секунду и стоя, и их молчание — потеря сигнала, а не стоянка.
    /// До 20.10 ниже 20 км/ч он не заряжался вовсе: подземный паркинг на
    /// 15 км/ч застывал со старой скоростью и висящим оповещением (S8).
    nonisolated static func watchdogArms(speedKmh: Double, distanceFilter: CLLocationDistance) -> Bool {
        speedKmh >= AppConfig.staleWatchdogMinSpeedKmh || distanceFilter <= 0
    }

    /// Спидометр без фиксов: раз в секунду скорость ограничивается сверху
    /// тем, что опровергает молчание GPS (SpeedBound), пока не станет нулём.
    /// Цикл живёт, только пока цифра ненулевая и фиксов нет, — на ходу его
    /// каждый фикс перезапускает, на стоянке он гаснет за несколько секунд.
    func armSpeedDecay() {
        speedDecayTask?.cancel()
        guard speedKmh > 0 else { return }
        let fixAt = Date()
        speedDecayTask = Task { [weak self] in
            while !Task.isCancelled {
                // Ошибка sleep — только отмена задачи; что делать после неё, решает проверка ниже.
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                let capped = SpeedBound.capped(self.speedKmh, distanceFilter: self.manager.distanceFilter,
                                               secondsSinceFix: Date().timeIntervalSince(fixAt))
                // Пишем только заметное изменение: speedKmh наблюдаемый.
                if abs(capped - self.speedKmh) >= 0.5 {
                    self.speedKmh = capped
                    // Флаг — следом за цифрой. Раньше он пересчитывался только
                    // на принятом фиксе со скоростью, а в помещении таких нет:
                    // спидометр гас до 0, а «Похоже, вы едете» висело до
                    // следующей поездки (телефон владельца, 11.10).
                    self.refreshDrivingFlag()
                }
                if self.speedKmh == 0 {
                    self.speedSmoother.reset()
                    // Скорость погасла без фиксов — стоим: следующий фикс-шум
                    // стрелку не сдвинет (Standstill).
                    self.standstill.stopIfIdle(at: self.displayCoordinate ?? self.currentCoordinate)
                    // Встали, а фиксов больше нет (distanceFilter): метан у
                    // АГНКС узнаёт о стоянке отсюда, иначе телефон в кармане
                    // у колонки не дождался бы вопроса никогда (ревью 12б.4).
                    if let here = self.displayCoordinate ?? self.currentCoordinate {
                        self.onStoppedWithoutFix?(here)
                    }
                    return
                }
            }
        }
    }

    func freezeDisplayIfStopped(shownBefore: CLLocationCoordinate2D?, courseBefore: CLLocationDirection) {
        guard standstill.isStopped else {
            frozenDisplay = nil
            return
        }
        if frozenDisplay == nil, let point = shownBefore ?? standstill.anchor ?? displayCoordinate {
            frozenDisplay = (point, courseBefore >= 0 ? courseBefore : standstill.anchorCourse)
        }
        guard let frozen = frozenDisplay else { return }
        displayCoordinate = frozen.coordinate
        if frozen.course >= 0 { displayCourse = frozen.course }
    }

    /// «Похоже, вы едете» по текущей цифре спидометра. Присваиваем ТОЛЬКО на
    /// изменение: @Observable будит подписчиков на каждую запись, а смысл
    /// флага ровно в том, чтобы их не будить.
    func refreshDrivingFlag() {
        let driving = Self.probablyDriving(was: isProbablyDriving, speedKmh: speedKmh,
                                           tripActive: isTripActive)
        if driving != isProbablyDriving { isProbablyDriving = driving }
    }

    func handleLocation(coordinate: CLLocationCoordinate2D, speed: CLLocationSpeed, course: CLLocationDirection) {
        // Главный горячий путь приложения: всё, что происходит на GPS-точке, —
        // на главном акторе, раз в секунду, всю поездку. В Instruments это один
        // интервал `handleLocation`; если он вырастет, вырастет и нагрев.
        Perf.measure(Perf.Name.handleLocation) {
            MainWork.during(MainWork.Name.gpsTick) {
                handleLocationBody(coordinate: coordinate, speed: speed, course: course)
            }
        }
    }

    func handleLocationBody(coordinate: CLLocationCoordinate2D, speed: CLLocationSpeed,
                                    course: CLLocationDirection) {
        currentCoordinate = coordinate
        let shownBefore = displayCoordinate
        let courseBefore = displayCourse
        standstill.update(coordinate, rawKmh: speed >= 0 ? speed * 3.6 : -1,
                          accuracy: horizontalAccuracy, course: course, at: Date())
        // Спидометр: сглаживание по ВРЕМЕНИ и мгновенный отклик на настоящий
        // перепад (SpeedSmoother — прежние константные веса на редких тиках
        // адаптивного GPS растягивали хвост торможения на 5+ секунд).
        // speed < 0 — фикс без скорости (туннель, плохая геометрия спутников): держим
        // прошлое значение, нулём считать нельзя — PassTracking берёт МИНИМУМ по зоне
        // проезда, и один такой фикс занизил бы записанную скорость у камеры.
        // На стоянке — ровно ноль: доплеровский шум приёмника на месте (2–7 км/ч)
        // не скорость (Standstill).
        if standstill.isStopped {
            speedSmoother.reset()
            if speedKmh != 0 { speedKmh = 0 }
            refreshDrivingFlag()
        } else if speed >= 0 {
            speedKmh = speedSmoother.update(rawKmh: speed * 3.6, at: Date())
            refreshDrivingFlag()
        }
        if speedKmh >= AppConfig.movementSeenSpeedKmh { lastMovementAt = Date() }
        if currentCourse != course { currentCourse = course }
        locationTick &+= 1
        onAcceptedFix?(coordinate)
        if isTripActive { noteDrivenFix(coordinate) } else if parkedCar != nil { refreshParkedCar() }
        retileIfNeeded(around: coordinate)
        recomputeNearest(from: coordinate, fromFix: true)
        recomputeDirection()

        // Активные оповещения (звук/голос/экран) — в поездке ИЛИ пока приложение открыто.
        if isTripActive || isForeground {
            trip.update(coordinate: coordinate, speedKmh: speedKmh, at: lastFixTime)
            // Геометрия проверяется в точке сближения, а не при захвате:
            // коридор оповещений на подходе широк намеренно (о камере за
            // поворотом молчать нельзя), и камера соседней улицы, попав под
            // него однажды, доезжала до записи в историю.
            register(passes: passTracking.update(
                nearest: nearestCamera, nearestDistance: distanceToNearest,
                coordinate: coordinate, speedKmh: speedKmh,
                roadLimit: speedLimits?.currentLimit,
                roadLimitAssumed: speedLimits?.isCurrentLimitAssumed ?? false,
                radius: effectiveAlertRadius,
                // Курс — тот же, которому верит весь конвейер: LocationFilter
                // отдаёт -1 там, где точность курса не доказана, и тогда
                // направление проезда честно остаётся неизвестным.
                course: course,
                offRoad: PassGeometry.isProvenOffRoad(camera:at:)))
            runAlertEngine()
            speakPostponedVoice()
            // Лимит дороги + превышение; манёвры и прогресс маршрута.
            // Здесь, а не в UI: голос должен работать со свёрнутым приложением.
            // Класс дороги ближайшей камеры — фолбэк лимита там, где OSM молчит.
            //
            // announce: отдельная фраза «Превышение скорости» звучит, только
            // если впереди НЕТ камеры, о которой мы сейчас скажем. Иначе
            // водитель получал две реплики внахлёст, и одна из них терялась —
            // чаще всего именно та, что про камеру. Про камеру фраза и так
            // содержит скорость с лимитом. Плюс настройка OverspeedVoice:
            // в режиме «У камер» фраза заслужена, только когда впереди по
            // нашей дороге камера в радиусе оповещения (просьба из реальной
            // поездки: честное по лимиту «превышение» без камеры — ворчание).
            let cameraAhead = (distanceToNearest ?? .greatestFiniteMagnitude)
                <= effectiveAlertRadius
            speedLimits?.update(
                coordinate: coordinate, course: course, speedKmh: speedKmh,
                // settings.voiceEnabled — общий выключатель голоса («Молча»,
                // в том числе кнопкой глушилки в машине). Его здесь не было:
                // камеры замолкали, а фраза о превышении продолжала звучать,
                // хотя человек только что попросил тишины. Настройка
                // overspeedVoice уточняет КОГДА говорить, но не отменяет
                // решения «не говорить вовсе».
                announce: isTripActive && settings.voiceEnabled
                    && !willSpeakAboutCameraAhead
                    && settings.overspeedVoice.allows(cameraAhead: cameraAhead),
                fallbackClass: nearestCamera?.roadClass ?? .unknown,
                // ПДД различают не класс дороги, а населённый пункт: в городе
                // 70 хоть на проспекте, хоть на жилой улице, за городом 100.
                inSettlement: alertContext == .city,
                // Впереди камера — порог превышения становится жёстче
                // штрафного, а подтверждение короче: предупреждение обязано
                // успеть раньше фиксации.
                cameraAhead: cameraAhead)
            // Смена лимита впереди — заранее, а не «превышение» после знака:
            // по линии маршрута или по оси текущей дороги (LimitAhead). Та же
            // тишина, что у фразы о превышении: «Молча», камера говорит сама.
            speedLimits?.checkLimitAhead(
                coordinate: coordinate, course: course, speedKmh: speedKmh,
                // Лениво: путь нужен раз в limitAheadCheckSeconds, а не на каждом тике.
                path: { [weak self] in
                    self?.route?.pathAhead(from: coordinate, meters: AppConfig.limitAheadMaxMeters + 100)
                },
                announce: isTripActive && settings.voiceEnabled && !willSpeakAboutCameraAhead)
            // Память о треногах — строго ПОСЛЕ speedLimits.update: подсказка
            // звучит только при превышении, а знает о нём именно он.
            announceHotspotIfNeeded(from: coordinate)
            // Перекрытие и ремонт впереди — спокойно, раз за поездку, и
            // только когда о камере сказать нечего: камера — выше.
            if !willSpeakAboutCameraAhead { announceRoadEventIfNeeded(from: coordinate) }
            // Прижим КАРТИНКИ к оси дороги — тем же RoadHit, что нашёл лимит,
            // без второго запроса. Строго после speedLimits.update и строго
            // только для отображения (см. RoadSnapper): гейты выше уже
            // отработали по сырому фиксу.
            let snapped = roadSnapper.update(course: currentCourse,
                                             hit: speedLimits?.currentRoadHit)
            let shown = snapped?.coordinate ?? coordinate
            if displayCoordinate.map({ $0.latitude != shown.latitude || $0.longitude != shown.longitude }) ?? true {
                displayCoordinate = shown
            }
            let shownCourse = snapped?.courseDegrees ?? currentCourse
            if displayCourse != shownCourse { displayCourse = shownCourse }
            // Стоянка: точка не сдвинулась — прогресс маршрута не мог
            // измениться, пересчёт (проекция, манёвры, префикс) пропускаем.
            // Порог накопительный от последней ОБРАБОТАННОЙ точки: ползание
            // набирает свои 2 м и проходит. У финиша (<300 м) не пропускаем
            // никогда — прибытие ползком в радиус срабатывает тик в тик.
            let progressMoved = lastRouteProgressCoordinate.map {
                GeoMath.fastDistance($0.latitude, $0.longitude,
                                     coordinate.latitude, coordinate.longitude)
            } ?? .greatestFiniteMagnitude
            // Объезд пробки — на каждом фиксе, и стоя: в пробке машина не
            // сдвигается, и прогресс ниже молчит ровно тогда, когда он нужен.
            if isTripActive { route?.considerDetour(coordinate: coordinate, speedKmh: speedKmh) }
            if progressMoved >= MapViewport.standstillMeters
                || (route?.remainingDistance ?? .greatestFiniteMagnitude) < 300 {
                lastRouteProgressCoordinate = coordinate
                // Курс — чтобы положение не прыгнуло на встречную ветку
                // маршрута там, где он возвращается сам к себе.
                route?.updateProgress(coordinate: coordinate, cameras: repository.cameras,
                                      announce: isTripActive, course: course)
            }
            // На маршруте стрелка садится на его линию: OSRM ведёт по нужной
            // проезжей части, и машина на карте едет по своей стороне
            // проспекта, а не рядом с линией (поездка 07.10.2026). Только
            // картинка, как и прижим к оси выше.
            if route?.isActive == true, let snap = route?.displaySnap {
                displayCoordinate = snap.coordinate
                displayCourse = snap.course
            }
            // Стоим — стрелка стоит там, где остановилась, и смотрит, куда
            // ехала: «после остановки куда-то назад уходил» — это блуждание
            // приёмника на месте, а не движение (владелец, 12.10).
            freezeDisplayIfStopped(shownBefore: shownBefore, courseBefore: courseBefore)
            tuneAdaptiveAccuracy()
            refreshCruise()
            // Умный режим: детектор города/трассы (дёшево — пара сравнений).
            contextDetector.update(roadLimitKmh: speedLimits?.certainLimit,
                                   camerasWithin3km: cameraDensity3km,
                                   speedKmh: speedKmh,
                                   roadClass: nearestCamera?.roadClass ?? .unknown)
            if contextDetector.context != alertContext { alertContext = contextDetector.context }
        }
        // Live Activity — только в поездке (условие внутри).
        refreshLiveActivity()
        // Часы: только в поездке. Вне её HUD часов рисует «нет поездки» без
        // цифр, а меняющаяся скорость пробивала дедуп и будила BT-радио ради
        // данных, которые часы не показывают. Переход в «нет поездки» шлёт
        // endTrip явными нулями.
        if isTripActive {
            watchBridge?.update(isTripActive: true, speedKmh: speedKmh,
                                cameraTitle: nearestCamera?.displayTitle,
                                cameraSymbol: nearestCamera?.kind.symbolName,
                                distanceMeters: distanceToNearest,
                                alertLevel: alertLevel,
                                limitKmh: speedLimits?.currentLimit,
                                // Устойчивое: мгновенный флаг щёлкает от шума
                                // GPS у самого лимита и будил бы радио часов
                                // раз в секунду (ревью 9.3).
                                isOverspeeding: speedLimits?.isOverspeedingSustained ?? false)
        }
    }

    func handleAuthChange(_ status: CLAuthorizationStatus) {
        authorizationStatus = status
        hasFullAccuracy = manager.accuracyAuthorization == .fullAccuracy
        switch status {
        case .authorizedWhenInUse:
            #if DEBUG
            // См. bootstrap(): в скриншот-прогонах симулятора диалог не показываем.
            if !ProcessInfo.processInfo.arguments.contains("-skipAlwaysPrompt") {
                manager.requestAlwaysAuthorization()
            }
            #else
            manager.requestAlwaysAuthorization()
            #endif
            startBackgroundMonitoring()
            applyLocationMode()
        case .authorizedAlways:
            startBackgroundMonitoring()
            applyLocationMode()
        case .denied, .restricted:
            // Доступа нет (отозвали на ходу или не давали) — фиксов не будет.
            // Ни застывшей скорости, ни висящего оповещения (сценарий S8,
            // 20.10). Поездку не закрываем: вернут доступ — applyLocationMode
            // продолжит её, а автостарт и геозоны останутся в порядке.
            manager.stopUpdatingLocation()
            staleWatchdogTask?.cancel()
            speedDecayTask?.cancel()
            isSignalStale = true
            if speedKmh != 0 { speedKmh = 0 }
            refreshDrivingFlag()
            clearNearest()
            if isTripActive { Log.location.notice("доступ к геопозиции отозван посреди поездки") }
        default:
            break
        }
    }
}
