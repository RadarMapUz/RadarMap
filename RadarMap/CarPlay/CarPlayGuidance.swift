//
//  CarPlayGuidance.swift
//  RadarMap
//
//  Ведение по маршруту на языке CarPlay: навигационная сессия, карточка
//  манёвра, время в пути, полосы и камеры.
//
//  До 10.10.2026 манёвр рисовался только своим SwiftUI-баннером поверх карты.
//  Пока на экране машины наше приложение, разницы почти нет; но стоит
//  водителю открыть музыку — и ни поворота, ни камеры: системные баннеры
//  CarPlay кормятся только из CPNavigationSession и CPNavigationAlert, а их не
//  было. Приборка и проекция на стекло тоже берут манёвр только отсюда.
//
//  Здесь — только пересказ состояния RouteService и LocationService. Решения
//  «когда предупреждать» остаются в конвейере оповещений: камера, о которой
//  здесь говорится, — та же, о которой уже говорит док.
//

import CarPlay
import MapKit
import UIKit
import os

/// Перевод нашего маршрута в типы CarPlay. Без UIKit-состояния — тестируется.
nonisolated enum CarPlayGuidanceMapping {

    /// Варианты фразы манёвра для карточки машины, от полной к короткой.
    /// CarPlay берёт первый, что помещается; без короткого узкая карточка
    /// оставалась пустой. С заглавной буквы — это подпись, а не продолжение
    /// фразы голоса.
    static func instructionVariants(text: String, shortText: String?) -> [String] {
        var result: [String] = []
        for variant in [text, shortText].compactMap({ $0 }) {
            let trimmed = variant.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let capitalized = trimmed.prefix(1).uppercased() + trimmed.dropFirst()
            if !result.contains(capitalized) { result.append(capitalized) }
        }
        return result.isEmpty ? [text] : result
    }

    /// Расстояние для карточки машины. Система печатает Measurement в ТОЙ
    /// единице, в которой его дали: метры давали «12,834 meter» на панели
    /// прибытия (CarPlay Simulator, 11.10). От километра — километры с
    /// десятой (дальше сотни — целые), ближе — метры, кратные десяти: «47 м»
    /// за рулём не читается точнее, чем «50 м».
    static func distance(meters: Double) -> Measurement<UnitLength> {
        let meters = max(0, meters)
        guard meters >= 1000 else {
            return Measurement(value: (meters / 10).rounded() * 10, unit: .meters)
        }
        let km = meters / 1000
        let shown = km >= 100 ? km.rounded() : (km * 10).rounded() / 10
        return Measurement(value: shown, unit: .kilometers)
    }

    /// Угол стрелки полосы, градусы: 0 — прямо, минус — влево, плюс — вправо.
    static func laneAngle(_ arrow: LaneArrow) -> Double {
        switch arrow {
        case .straight:     return 0
        case .slightLeft:   return -45
        case .left:         return -90
        case .sharpLeft:    return -135
        case .uturn:        return -180
        case .slightRight:  return 45
        case .right:        return 90
        case .sharpRight:   return 135
        case .mergeToLeft:  return -30
        case .mergeToRight: return 30
        }
    }

    /// Полоса для CarPlay: все стрелки, подсвеченная — та, что ведёт по
    /// маршруту (её нет у неподходящей полосы).
    struct Lane: Equatable {
        let angles: [Double]
        let highlighted: Double?
    }

    /// Ряд полос. Подсвеченный угол не входит в `angles` — так требует CPLane.
    static func lanes(_ hints: [LaneHint], kind: ManeuverKind?) -> [Lane] {
        hints.map { hint in
            let all = uniqued(hint.arrows.map(laneAngle))
            guard hint.isValid else { return Lane(angles: all, highlighted: nil) }
            let main = laneAngle(hint.primaryArrow(for: kind))
            return Lane(angles: all.filter { $0 != main }, highlighted: main)
        }
    }

    /// Ряд полос имеет смысл, только если есть и куда ехать, и что отличать:
    /// все полосы годятся — подсказка пустая.
    static func isUseful(_ lanes: [Lane]) -> Bool {
        lanes.contains { $0.highlighted != nil } && lanes.contains { $0.highlighted == nil }
    }

    static func maneuverType(_ kind: ManeuverKind?) -> CPManeuverType {
        switch kind {
        case .straight:    return .straightAhead
        case .slightLeft:  return .slightLeftTurn
        case .left:        return .leftTurn
        case .sharpLeft:   return .sharpLeftTurn
        case .uturn:       return .uTurn
        case .slightRight: return .slightRightTurn
        case .right:       return .rightTurn
        case .sharpRight:  return .sharpRightTurn
        case .roundabout:  return .enterRoundabout
        case .arrive:      return .arriveAtDestination
        case nil:          return .noTurn
        }
    }

    // MARK: - Метаданные для приборки и проекции (CarPlayNavigationMetadata)

    /// Тип перекрёстка: кольцо или обычный. Поле, без которого машина с
    /// приборкой рисовала карточку манёвра пустой (2.2.4–2.2.7).
    static func junctionType(_ kind: ManeuverKind?) -> CPJunctionType {
        kind == .roundabout ? .roundabout : .intersection
    }

    /// Угол съезда, градусы: 0 — прямо, минус — влево (то же соглашение, что
    /// у полос). nil — манёвр не поворот (прибытие) или тип неизвестен.
    static func exitAngle(_ kind: ManeuverKind?) -> Double? {
        switch kind {
        case .straight:    return 0
        case .slightLeft:  return -45
        case .left:        return -90
        case .sharpLeft:   return -135
        case .uturn:       return -180
        case .slightRight: return 45
        case .right:       return 90
        case .sharpRight:  return 135
        case .roundabout, .arrive, nil: return nil
        }
    }

    /// Состояние манёвра по мере подъезда — как у встроенных навигаторов:
    /// «едем» вдали, «готовься» на подходе, «выполняй» у самого поворота.
    /// Новый манёвр первые метры — «начальный».
    static func maneuverState(distance: Double, sinceShown: TimeInterval) -> CPManeuverState {
        if distance <= AppConfig.carPlayManeuverExecuteMeters { return .execute }
        if distance <= AppConfig.carPlayManeuverPrepareMeters { return .prepare }
        if sinceShown < AppConfig.carPlayManeuverInitialSeconds { return .initial }
        return .continue
    }

    /// Время до манёвра — долей оставшегося времени: скорость по маршруту
    /// известна только целиком, а доля пути — честная оценка без выдумки.
    static func timeToManeuver(stepDistance: Double, remainingDistance: Double,
                               remainingTime: Double) -> Double {
        guard remainingDistance > 0, remainingTime > 0 else { return 0 }
        return remainingTime * min(1, max(0, stepDistance / remainingDistance))
    }

    /// Пора ли слать новую оценку в машину. Каждое обновление — сообщение на
    /// головное устройство: шлём, когда цифра на экране правда сменится
    /// (шаг 10 м вблизи, 5 % вдали) или раз в несколько секунд на стоянке.
    static func shouldUpdate(previous: Double?, current: Double, elapsed: TimeInterval) -> Bool {
        guard let previous else { return true }
        if elapsed >= AppConfig.carPlayEstimateMaxInterval { return true }
        return abs(previous - current) >= max(AppConfig.carPlayEstimateMinStepMeters, previous * 0.05)
    }

    private static func uniqued(_ values: [Double]) -> [Double] {
        var seen = Set<Double>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// Навигационная сессия CarPlay поверх RouteService. Живёт столько же,
/// сколько подключение к машине.
@MainActor
final class CarPlayGuidance {
    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей.
    nonisolated deinit {}

    private weak var template: CPMapTemplate?
    private let model: CarPlayMapModel
    private var session: CPNavigationSession?
    private var trip: CPTrip?
    private var tripDestination: CLLocationCoordinate2D?
    private var maneuver: CPManeuver?
    private var maneuverStep: RouteStep?
    /// CPManeuver держит связанные полосы ссылкой `assign` (не удерживает):
    /// отпустить ряд, пока на него смотрит ещё живой манёвр, значит оставить
    /// машине висячий указатель. Поэтому все ряды сессии живут до её конца.
    private var laneGuidances: [CPLaneGuidance] = []
    private var sentStepDistance: Double?
    private var sentStepTime = Date.distantPast
    private var sentTripDistance: Double?
    private var sentTripTime = Date.distantPast
    private var alertedCameraID: Int?
    /// Когда показан текущий манёвр — для состояния «начальный».
    private var maneuverShownAt = Date.distantPast
    private var sentManeuverState: CPManeuverState?
    /// Ведение на паузе «Перестраиваю маршрут» (CPTripPauseReason.rerouting).
    private var pausedForReroute = false
    private var generation = 0
    /// Наше приложение на экране машины. Пока да — камеру показывает док и
    /// баннер приближения, а системный баннер был бы вторым о том же.
    /// Изначально «нет»: сцена может подключиться в фоне и так и не стать
    /// активной, а `sceneDidBecomeActive` ставит «да» сам.
    var isOnScreen = false

    private var env: AppEnvironment { .shared }

    init(model: CarPlayMapModel) {
        self.model = model
    }

    func attach(to template: CPMapTemplate) {
        self.template = template
        generation &+= 1
        observe()
    }

    /// Водитель ушёл с нашего экрана (главный экран машины, музыка) или
    /// вернулся: манёвр и оценки — заново. Плитка инструкций на главном
    /// экране рисует то, что сессия прислала ПОСЛЕДНИМ (carplay12: на главном
    /// экране «Дом / Работа» при живом маршруте).
    ///
    /// `driverReturned` — водитель сам открыл RadarMap на экране машины. Если
    /// перед этим навигацию забрала система (другой навигатор начал свою),
    /// ведение к той же цели снова наше: до 2.2.16 сессия после такой отмены
    /// не возвращалась до конца маршрута — ни манёвра, ни прибытия нигде.
    func refresh(reason: String, driverReturned: Bool = false) {
        if driverReturned, cancelledDestination != nil {
            cancelledDestination = nil
            Log.carplay.notice("водитель вернулся к RadarMap — ведение снова наше")
        }
        Log.carplay.notice("ведение заново (\(reason, privacy: .public)): маршрут \(self.env.route.isActive, privacy: .public), сессия \(self.session != nil, privacy: .public), манёвр \(self.maneuver != nil, privacy: .public)")
        guard template != nil else { return }
        sentStepDistance = nil
        sentTripDistance = nil
        if let session, let maneuver {
            session.upcomingManeuvers = [maneuver]
        }
        // Запускает сессию, если её нет, и шлёт оценки (сброшены выше).
        sync()
    }

    /// Навигацию забрала система: сессии нет, и для ЭТОЙ цели её не
    /// перезапускаем — иначе шаблон и система дрались бы за экран до конца
    /// маршрута. Новый маршрут (другая цель) начнёт сессию заново.
    func systemCancelled() {
        session = nil
        trip = nil
        maneuver = nil
        maneuverStep = nil
        laneGuidances = []
        pausedForReroute = false
        cancelledDestination = tripDestination
        model.hasSystemGuidance = false
    }
    private var cancelledDestination: CLLocationCoordinate2D?

    /// Машина отключилась: сессия уходит вместе с шаблоном, держать нечего.
    func detach() {
        generation &+= 1
        session = nil
        trip = nil
        maneuver = nil
        maneuverStep = nil
        laneGuidances = []
        pausedForReroute = false
        template = nil
        themedDaylight = nil
        model.hasSystemGuidance = false
    }

    /// Цвет карточки манёвра — в тон теме экрана машины: поверхность
    /// палитры (Theme.surface), белая днём, графит ночью. Синей, как на
    /// телефоне, системную карточку не делаем, пока не проверено в машине:
    /// вариант значка (чёрный/белый) CarPlay выбирает сам, и чёрная стрелка
    /// на синем — хуже, чем разный цвет карточки на двух экранах.
    func applyTheme(daylight: Bool) {
        template?.guidanceBackgroundColor = daylight ? Theme.rgb(0xFFFFFF) : Theme.rgb(0x1E232A)
    }

    // MARK: - Наблюдение

    private func observe() {
        let generation = generation
        withObservationTracking {
            sync()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.observe()
            }
        }
    }

    private var themedDaylight: Bool?

    private func sync() {
        guard let template else { return }
        if themedDaylight != model.isDaylight {
            themedDaylight = model.isDaylight
            applyTheme(daylight: model.isDaylight)
            // Стрелка красится под фон карточки — сменился фон, пересобираем.
            maneuverStep = nil
        }
        let route = env.route
        // Выбор маршрута на экране: сессия — только после «Поехали» (так
        // устроен CarPlay: предпросмотр, затем startNavigationSession). Старое
        // ведение к прежней цели при этом заканчиваем: маршрут уже другой.
        if model.isPreviewing {
            if let session {
                session.cancelTrip()
                session.upcomingManeuvers = []
                self.session = nil
                trip = nil
                maneuver = nil
                maneuverStep = nil
                laneGuidances = []
                pausedForReroute = false
                model.hasSystemGuidance = false
            }
            alertCamera(on: template)
            return
        }
        // Ведём только в поездке (NavigationFlow): маршрут без поездки — это
        // выбор с «Поехали», и на телефоне, и здесь. До 12.10 машина вела по
        // любому маршруту — после «Стоп» и под «Поехали» на телефоне.
        let phase = NavigationFlow.phase(hasRoute: route.isActive, isTripActive: env.location.isTripActive)
        if NavigationFlow.carGuides(phase: phase, choosing: model.isPreviewing),
           let destination = route.destinationCoordinate {
            let cancelledHere = cancelledDestination.map { Self.same($0, destination) } ?? false
            if !cancelledHere,
               session == nil || tripDestination.map({ !Self.same($0, destination) }) ?? true {
                cancelledDestination = nil
                start(on: template, to: destination)
            }
            // Перестроение: старый поворот уже неверен — пауза с причиной, как
            // у Mapbox. Снимает её новый манёвр (upcomingManeuvers), а если
            // перестроить не удалось — прежний: карточка «перестраиваю» не
            // застревает ни в одном исходе.
            if route.isRerouting {
                if let session, !pausedForReroute {
                    pausedForReroute = true
                    session.pauseTrip(for: .rerouting,
                                      description: String(localized: "Перестраиваю маршрут"))
                    Log.carplay.notice("ведение: пауза на перестроение")
                }
            } else if pausedForReroute {
                pausedForReroute = false
                maneuverStep = nil   // манёвр — заново: это и снимает паузу
                Log.carplay.notice("ведение: перестроение закончено")
            }
            if !pausedForReroute { updateManeuver() }
            updateEstimates(on: template)
        } else if let session {
            // Маршрут снят или поездка кончилась: доехали — «завершить»,
            // иначе — «отменить».
            // Разница видна водителю: CarPlay по-разному прощается с поездкой.
            if let arrival = route.lastArrival,
               Date().timeIntervalSince(arrival.at) < AppConfig.carPlayArrivalFreshSeconds {
                session.finishTrip()
            } else {
                session.cancelTrip()
            }
            session.upcomingManeuvers = []
            session.currentLaneGuidance = nil
            self.session = nil
            trip = nil
            maneuver = nil
            maneuverStep = nil
            laneGuidances = []
            pausedForReroute = false
            model.hasSystemGuidance = false
        }
        alertCamera(on: template)
    }

    // MARK: - Сессия

    private func start(on template: CPMapTemplate, to destination: CLLocationCoordinate2D) {
        if let session {
            session.upcomingManeuvers = []
            session.currentLaneGuidance = nil
            session.cancelTrip()
        }
        let route = env.route
        let from = env.location.currentCoordinate ?? destination
        let origin = MKMapItem(placemark: MKPlacemark(coordinate: from))
        let target = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        target.name = route.destinationName.isEmpty ? nil : route.destinationName
        let summary = [route.distanceText, route.etaText].filter { !$0.isEmpty }.joined(separator: " · ")
        let choice = CPRouteChoice(summaryVariants: [summary.isEmpty ? route.destinationName : summary],
                                   additionalInformationVariants: [],
                                   selectionSummaryVariants: [])
        let trip = CPTrip(origin: origin, destination: target, routeChoices: [choice])
        self.trip = trip
        tripDestination = destination
        session = template.startNavigationSession(for: trip)
        maneuver = nil
        maneuverStep = nil
        laneGuidances = []
        pausedForReroute = false
        sentStepDistance = nil
        sentTripDistance = nil
        model.hasSystemGuidance = true
        Log.carplay.notice("CarPlay: навигационная сессия начата")
    }

    private func updateManeuver() {
        guard let session else { return }
        let step = env.route.nextStep
        guard step != maneuverStep else { return }
        maneuverStep = step
        sentStepDistance = nil
        guard let step else {
            // Маршрут ещё идёт, а следующего шага нет (пересчёт, последние
            // метры): прежний манёвр ОСТАЁТСЯ. Пустой список манёвров при живой
            // сессии машина читает как «ведения нет» — и плитка главного экрана
            // показывает «Дом / Работа» вместо поворота (carplay12, 12.10).
            if maneuver == nil {
                session.upcomingManeuvers = []
                session.currentLaneGuidance = nil
            }
            Log.carplay.notice("манёвра нет — в машине остаётся прежний: \(self.maneuver != nil, privacy: .public)")
            return
        }
        let next = CPManeuver()
        next.instructionVariants = CarPlayGuidanceMapping.instructionVariants(
            text: step.text, shortText: step.shortText)
        // Плитка главного экрана — та же фраза явно, а не через запасной путь.
        next.dashboardInstructionVariants = next.instructionVariants
        // Цвет стрелки — под фон НАШЕЙ карточки (guidanceBackgroundColor:
        // белая днём, графит ночью): до машины доезжает одна картинка, та,
        // что создана. Баннеры поверх чужого приложения и плитка панели
        // рисуются в теме МАШИНЫ — им свой цвет.
        let symbolName = step.kind?.isDrawable == false ? "flag.checkered" : step.icon
        next.symbolImage = Self.symbol(symbolName, pointSize: 34, onDark: !model.isDaylight)
        let carDark = model.carIsDark ?? !model.isDaylight
        next.notificationSymbolImage = Self.symbol(symbolName, pointSize: 34, onDark: carDark)
        next.dashboardSymbolImage = Self.symbol(symbolName, pointSize: 34, onDark: carDark)
        // Схема развязки — для узла с другими дорогами (JunctionSketch): какой
        // из трёх правых съездов наш, стрелка не говорит.
        if let plan = junctionPlan(for: step) {
            next.junctionImage = Self.junctionImage(plan, onDark: !model.isDaylight)
            next.dashboardJunctionImage = Self.junctionImage(plan, onDark: carDark)
        }
        next.maneuverType = CarPlayGuidanceMapping.maneuverType(step.kind)
        next.trafficSide = .right
        next.junctionType = CarPlayGuidanceMapping.junctionType(step.kind)
        if let angle = CarPlayGuidanceMapping.exitAngle(step.kind) {
            next.junctionExitAngle = Measurement(value: angle, unit: .degrees)
        }
        maneuverShownAt = Date()
        sentManeuverState = nil
        let lanes = CarPlayGuidanceMapping.lanes(step.lanes, kind: step.kind)
        if CarPlayGuidanceMapping.isUseful(lanes) {
            let guidance = CPLaneGuidance()
            guidance.lanes = lanes.map { lane in
                let angles = lane.angles.map { Measurement(value: $0, unit: UnitAngle.degrees) }
                guard let highlighted = lane.highlighted else { return CPLane(angles: angles) }
                return CPLane(angles: angles,
                              highlightedAngle: Measurement(value: highlighted, unit: UnitAngle.degrees),
                              isPreferred: true)
            }
            guidance.instructionVariants = next.instructionVariants
            laneGuidances.append(guidance)
            session.add([guidance])
            next.linkedLaneGuidance = guidance
            session.currentLaneGuidance = guidance
        } else {
            session.currentLaneGuidance = nil
        }
        // Начальная оценка — в самом манёвре, как у Mapbox: карточка не ждёт
        // первого updateEstimates, чтобы показать расстояние до поворота.
        let distance = env.route.nextStepDistance
        next.initialTravelEstimates = Self.estimates(
            meters: distance,
            seconds: CarPlayGuidanceMapping.timeToManeuver(stepDistance: distance,
                                                           remainingDistance: env.route.remainingDistance,
                                                           remainingTime: env.route.remainingTime))
        // Улика на случай пустой карточки: что именно ушло в машину.
        Log.carplay.notice("манёвр в машину: вариантов \(next.instructionVariants.count, privacy: .public), первый \(next.instructionVariants.first?.count ?? 0, privacy: .public) симв., стрелка \(next.symbolImage != nil, privacy: .public), \(Int(distance), privacy: .public) м")
        maneuver = next
        // Каждый манёвр, попадающий в upcomingManeuvers, сначала регистрируется
        // в сессии (CPNavigationSession.h, iOS 17.4+): без этого приборка и
        // проекция на стекло могут не получить его вовсе.
        session.add([next])
        session.upcomingManeuvers = [next]
    }

    private func updateEstimates(on template: CPMapTemplate) {
        let route = env.route
        let now = Date()
        if let session, maneuver != nil, maneuverStep != nil, AppConfig.carPlayNavigationMetadata {
            let state = CarPlayGuidanceMapping.maneuverState(distance: route.nextStepDistance,
                                                             sinceShown: now.timeIntervalSince(maneuverShownAt))
            if state != sentManeuverState {
                sentManeuverState = state
                session.maneuverState = state
            }
        }
        if let session, let maneuver, maneuverStep != nil {
            let distance = route.nextStepDistance
            if CarPlayGuidanceMapping.shouldUpdate(previous: sentStepDistance, current: distance,
                                                   elapsed: now.timeIntervalSince(sentStepTime)) {
                sentStepDistance = distance
                sentStepTime = now
                let time = CarPlayGuidanceMapping.timeToManeuver(stepDistance: distance,
                                                                 remainingDistance: route.remainingDistance,
                                                                 remainingTime: route.remainingTime)
                session.updateEstimates(Self.estimates(meters: distance, seconds: time), for: maneuver)
            }
        }
        if let trip {
            let distance = route.remainingDistance
            if CarPlayGuidanceMapping.shouldUpdate(previous: sentTripDistance, current: distance,
                                                   elapsed: now.timeIntervalSince(sentTripTime)) {
                sentTripDistance = distance
                sentTripTime = now
                template.updateEstimates(Self.estimates(meters: distance, seconds: route.remainingTime),
                                         for: trip)
            }
        }
    }

    // MARK: - Камера, когда на экране машины не мы

    /// Системный баннер о камере — только когда водитель смотрит не на нас
    /// (музыка, звонок): на нашем экране о ней уже говорит док. Один раз на
    /// камеру; решение «предупреждать ли» уже приняли гейты оповещений.
    private func alertCamera(on template: CPMapTemplate) {
        let location = env.location
        guard location.isApproachingCamera, let camera = location.nearestCamera,
              let distance = location.distanceToNearest else {
            if !location.isApproachingCamera { alertedCameraID = nil }
            return
        }
        guard camera.id != alertedCameraID, !isOnScreen else { return }
        // Отмечаем только показанное: ушёл водитель в музыку посреди подхода —
        // баннер о той же камере должен появиться, а не считаться отданным.
        alertedCameraID = camera.id
        let far = Formatting.distance(distance)
        let alert = CPNavigationAlert(
            titleVariants: [String(format: String(localized: "%1$@ через %2$@"), camera.kind.shortName, far),
                            camera.kind.shortName],
            subtitleVariants: [camera.kind.displayName],
            image: Self.symbol(camera.kind.symbolName, pointSize: 30,
                               onDark: model.carIsDark ?? !model.isDaylight),
            primaryAction: CPAlertAction(title: String(localized: "Понятно"), style: .cancel) { _ in },
            secondaryAction: nil,
            duration: AppConfig.carPlayCameraAlertSeconds)
        // Пока виден прежний баннер, новый CarPlay молча не покажет (минимум
        // показа — 8 с): вторая камера подряд терялась бы. Убираем прежний.
        guard template.currentNavigationAlert != nil else {
            return template.present(navigationAlert: alert, animated: true)
        }
        template.dismissNavigationAlert(animated: false) { [weak template] _ in
            Task { @MainActor in template?.present(navigationAlert: alert, animated: true) }
        }
    }

    // MARK: - Картинки и оценки

    static func estimates(meters: Double, seconds: Double) -> CPTravelEstimates {
        CPTravelEstimates(distanceRemaining: CarPlayGuidanceMapping.distance(meters: meters),
                          timeRemaining: max(0, seconds))
    }

    /// План схемы развязки для шага или nil — узел простой или сети нет.
    private func junctionPlan(for step: RouteStep) -> JunctionSketch.Plan? {
        guard step.kind?.isDrawable == true, let route = env.route.selected else { return nil }
        let coordinates = route.points.map(\.coordinate)
        guard let center = JunctionSketch.point(on: coordinates, at: step.distanceAlong) else { return nil }
        let roads = env.roads.network
            .roads(near: center, radius: AppConfig.junctionRadiusMeters * 1.2)
            .map(\.points)
        guard let plan = JunctionSketch.plan(route: coordinates, maneuverAlong: step.distanceAlong, roads: roads),
              plan.roads.count >= AppConfig.junctionMinRoads else { return nil }
        return plan
    }

    /// Картинка схемы: дороги узла серым, наш путь — цветом маршрута со
    /// стрелкой на съезде. Фон прозрачный — под ним карточка манёвра.
    static func junctionImage(_ plan: JunctionSketch.Plan, onDark: Bool) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = AppConfig.carPlaySymbolScale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: plan.size, format: format).image { context in
            let g = context.cgContext
            g.setLineCap(.round)
            g.setLineJoin(.round)
            func stroke(_ line: [CGPoint]) {
                guard let first = line.first else { return }
                g.beginPath()
                g.move(to: first)
                for point in line.dropFirst() { g.addLine(to: point) }
                g.strokePath()
            }
            g.setStrokeColor((onDark ? UIColor(white: 1, alpha: 0.30) : UIColor(white: 0, alpha: 0.20)).cgColor)
            g.setLineWidth(7)
            plan.roads.forEach(stroke)
            let route = onDark ? Theme.rgb(0x5B9BFF) : Theme.rgb(0x2A6FF0)
            g.setStrokeColor(route.cgColor)
            g.setLineWidth(6)
            stroke(plan.path)
            // Стрелка на конце съезда.
            if plan.path.count >= 2 {
                let tip = plan.path[plan.path.count - 1], from = plan.path[plan.path.count - 2]
                let angle = atan2(tip.y - from.y, tip.x - from.x)
                let size: CGFloat = 9
                g.setFillColor(route.cgColor)
                g.beginPath()
                g.move(to: CGPoint(x: tip.x + cos(angle) * size, y: tip.y + sin(angle) * size))
                g.addLine(to: CGPoint(x: tip.x + cos(angle + 2.4) * size, y: tip.y + sin(angle + 2.4) * size))
                g.addLine(to: CGPoint(x: tip.x + cos(angle - 2.4) * size, y: tip.y + sin(angle - 2.4) * size))
                g.closePath()
                g.fillPath()
            }
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    /// Значок для карточки CarPlay: белый на тёмном фоне, чёрный на светлом.
    ///
    /// Готовая растровая картинка, а не символ: до 2.2.15 здесь собирался
    /// пустой `UIImageAsset()` из двух вариантов символа, и
    /// `asset.image(with:)` возвращал nil (проверено на симуляторе 12.10) —
    /// у карточки манёвра, баннера и плитки панели стрелки не было НИКОГДА
    /// («в карточке одно расстояние», 11.10), а системный алерт камеры шёл
    /// без значка. Журнал carplay11 это и показал: «стрелка false». Отдаётся
    /// один вариант под известный нам фон — варианты внутри одного ассета до
    /// машины не доезжают.
    static func symbol(_ name: String, pointSize: CGFloat, onDark: Bool) -> UIImage? {
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
        guard let base = UIImage(systemName: name, withConfiguration: configuration)
                ?? UIImage(systemName: "arrow.up", withConfiguration: configuration) else { return nil }
        let tinted = base.withTintColor(onDark ? .white : .black, renderingMode: .alwaysOriginal)
        let format = UIGraphicsImageRendererFormat()
        // Экран машины бывает @3x — рисуем с запасом, а не в масштабе телефона.
        format.scale = AppConfig.carPlaySymbolScale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: base.size, format: format).image { _ in
            tinted.draw(in: CGRect(origin: .zero, size: base.size))
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    static func same(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
        GeoMath.fastDistance(a.latitude, a.longitude, b.latitude, b.longitude)
            < AppConfig.carPlaySameDestinationMeters
    }
}
