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
    /// CPManeuver держит связанные полосы слабой (assign) ссылкой — держим мы.
    private var laneGuidance: CPLaneGuidance?
    private var sentStepDistance: Double?
    private var sentStepTime = Date.distantPast
    private var sentTripDistance: Double?
    private var sentTripTime = Date.distantPast
    private var alertedCameraID: Int?
    private var generation = 0
    /// Наше приложение на экране машины. Пока да — камеру показывает док и
    /// баннер приближения, а системный баннер был бы вторым о том же.
    var isOnScreen = true

    private var env: AppEnvironment { .shared }

    init(model: CarPlayMapModel) {
        self.model = model
    }

    func attach(to template: CPMapTemplate) {
        self.template = template
        generation &+= 1
        observe()
    }

    /// Машина отключилась: сессия уходит вместе с шаблоном, держать нечего.
    func detach() {
        generation &+= 1
        session = nil
        trip = nil
        maneuver = nil
        maneuverStep = nil
        laneGuidance = nil
        template = nil
        themedDaylight = nil
        model.hasSystemGuidance = false
    }

    /// Цвет карточки манёвра — в тон теме экрана машины.
    func applyTheme(daylight: Bool) {
        template?.guidanceBackgroundColor = daylight ? .white : UIColor(white: 0.12, alpha: 1)
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
        }
        let route = env.route
        if route.isActive, let destination = route.destinationCoordinate {
            if session == nil || tripDestination.map({ !Self.same($0, destination) }) ?? true {
                start(on: template, to: destination)
            }
            updateManeuver()
            updateEstimates(on: template)
        } else if let session {
            // Маршрут снят: доехали — «завершить», иначе — «отменить».
            // Разница видна водителю: CarPlay по-разному прощается с поездкой.
            if let arrival = route.lastArrival, Date().timeIntervalSince(arrival.at) < 10 {
                session.finishTrip()
            } else {
                session.cancelTrip()
            }
            self.session = nil
            trip = nil
            maneuver = nil
            maneuverStep = nil
            laneGuidance = nil
            model.hasSystemGuidance = false
        }
        alertCamera(on: template)
    }

    // MARK: - Сессия

    private func start(on template: CPMapTemplate, to destination: CLLocationCoordinate2D) {
        session?.cancelTrip()
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
            maneuver = nil
            session.upcomingManeuvers = []
            session.currentLaneGuidance = nil
            return
        }
        let next = CPManeuver()
        next.instructionVariants = [step.text]
        next.symbolImage = Self.symbol(step.kind?.isDrawable == false ? "flag.checkered" : step.icon,
                                       pointSize: 34)
        next.maneuverType = CarPlayGuidanceMapping.maneuverType(step.kind)
        next.trafficSide = .right
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
            guidance.instructionVariants = [step.text]
            session.add([guidance])
            next.linkedLaneGuidance = guidance
            laneGuidance = guidance
            session.currentLaneGuidance = guidance
        } else {
            laneGuidance = nil
            session.currentLaneGuidance = nil
        }
        maneuver = next
        session.upcomingManeuvers = [next]
    }

    private func updateEstimates(on template: CPMapTemplate) {
        let route = env.route
        let now = Date()
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
        guard camera.id != alertedCameraID else { return }
        alertedCameraID = camera.id
        guard !isOnScreen else { return }
        let far = Formatting.distance(distance)
        let alert = CPNavigationAlert(
            titleVariants: [String(format: String(localized: "%@ через %@"), camera.kind.shortName, far),
                            camera.kind.shortName],
            subtitleVariants: [camera.kind.displayName],
            image: Self.symbol(camera.kind.symbolName, pointSize: 30),
            primaryAction: CPAlertAction(title: String(localized: "Понятно"), style: .cancel) { _ in },
            secondaryAction: nil,
            duration: AppConfig.carPlayCameraAlertSeconds)
        template.present(navigationAlert: alert, animated: true)
    }

    // MARK: - Картинки и оценки

    private static func estimates(meters: Double, seconds: Double) -> CPTravelEstimates {
        CPTravelEstimates(distanceRemaining: Measurement(value: max(0, meters), unit: UnitLength.meters),
                          timeRemaining: max(0, seconds))
    }

    /// Значок для карточки CarPlay в двух вариантах — тёмный на светлой
    /// карточке и белый на тёмной: машина сама выбирает по своей теме.
    static func symbol(_ name: String, pointSize: CGFloat) -> UIImage? {
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
        guard let base = UIImage(systemName: name, withConfiguration: configuration)
                ?? UIImage(systemName: "arrow.up", withConfiguration: configuration) else { return nil }
        let asset = UIImageAsset()
        asset.register(base.withTintColor(.black, renderingMode: .alwaysOriginal),
                       with: UITraitCollection(userInterfaceStyle: .light))
        asset.register(base.withTintColor(.white, renderingMode: .alwaysOriginal),
                       with: UITraitCollection(userInterfaceStyle: .dark))
        return asset.image(with: UITraitCollection(userInterfaceStyle: .dark))
    }

    private static func same(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
        GeoMath.fastDistance(a.latitude, a.longitude, b.latitude, b.longitude) < 30
    }
}
