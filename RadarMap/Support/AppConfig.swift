//
//  AppConfig.swift
//  RadarMap
//
//  Единая точка настройки всех констант приложения.
//

import Foundation
import CoreLocation
import MapKit

enum AppConfig {

    // MARK: - Оповещения / геолокация

    /// Радиус срабатывания оповещения о камере (метры). Вынесено в константу — легко менять.
    static let alertRadius: CLLocationDistance = 400

    /// Максимум одновременно отслеживаемых регионов. Жёсткое ограничение iOS.
    static let maxMonitoredRegions = 20

    /// Насколько пользователь должен сместиться, прежде чем пересчитать 20 ближайших камер.
    /// Меньше значение — свежее набор камер, чуть больше пробуждений. 1.5 км — баланс для города/трассы.
    static let retileDistance: CLLocationDistance = 1500

    /// Адаптивный GPS: финальный подход к камере/манёвру — держим максимальную точность
    /// (нужен точный отсчёт расстояния и учёт проезда: зона измерения 80 м попадает сюда).
    static let gpsPreciseApproachMeters: CLLocationDistance = 500
    /// Ближе этого, но дальше «финала» — точность 10 м и реже колбэки: экономим чип и
    /// частоту всего пайплайна. Дальше — ещё мягче. В плотном городе так GPS большую часть
    /// пути идёт на среднем/мягком тире вместо постоянного максимума (меньше нагрев).
    static let gpsMidApproachMeters: CLLocationDistance = 1500
    /// Стоянка в поездке (пробка, светофор, парковка с невыключенной поездкой):
    /// столько секунд без движения — и GPS падает до самого мягкого тира.
    /// Первый же тик с движением возвращает точность: на 30-метровом фильтре
    /// он приходит через пару секунд после старта — камеры дальше 1.5 км, успеваем.
    static let gpsIdleAfterSeconds: TimeInterval = 60

    // MARK: - Умный режим оповещений (город/трасса) — пороги детектора.
    // nonisolated: читаются из чистого AlertPolicy (и его тестов) без прыжка на main.

    /// Лимит дороги ≥ этого — голос за трассу (самый сильный сигнал).
    nonisolated static let highwayLimitKmh = 90
    /// Лимит ≤ этого — голос за город.
    nonisolated static let cityLimitKmh = 60
    /// Средняя скорость (EMA ~2 мин) выше — похоже на трассу.
    nonisolated static let highwayAvgSpeedKmh: Double = 78
    /// Средняя ниже — городской ритм со светофорами.
    nonisolated static let cityAvgSpeedKmh: Double = 55
    /// Камер в радиусе 3 км не меньше этого — плотная городская сетка.
    nonisolated static let cityCameraDensity = 6
    /// Контекст не переключается чаще: светофор на трассе — ещё не город.
    nonisolated static let alertContextSwitchSeconds: TimeInterval = 180

    // MARK: - Карта

    /// Центр Узбекистана — запасная позиция карты, пока нет геопозиции пользователя.
    static let uzbekistanRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 41.377, longitude: 64.585),
        span: MKCoordinateSpan(latitudeDelta: 8.0, longitudeDelta: 12.0)
    )

    /// Максимум аннотаций, рисуемых на карте одновременно (плавность + экономия ресурсов).
    static let maxVisibleAnnotations = 220

    /// Если область карты шире этого значения по широте — точки не рисуем, просим приблизить.
    static let maxVisibleSpanDegrees = 1.2

    /// Средний зум (шире этого по широте): камеры рисуются маленькими точками,
    /// полноразмерный пин — только у ближайшей и выбранной. Карта не превращается в кашу.
    static let dotModeSpanDegrees = 0.035

    /// Во сколько раз расширяем видимую область при подгрузке аннотаций.
    /// Буфер держит точки уже отрисованными за краями экрана → панорамирование без «подпрыгивания».
    static let annotationBufferFactor = 1.8

    /// Насколько сильно должна измениться область, чтобы пересчитать аннотации (доля буфера).
    /// Небольшие сдвиги внутри буфера пропускаем — это и есть «умный» зум.
    static let recomputeThreshold = 0.35

    /// Дистанция камеры (метры) при центрировании на выбранной камере из списка.
    static let focusDistance: CLLocationDistance = 1200

    /// На широких зумах камеры группируются в кластеры: сетка N×N ячеек на экран.
    static let clusterGridDivisions = 5.0

    // MARK: - Направленные оповещения (только камеры впереди по курсу)

    /// Минимальная скорость, при которой GPS-курс достоверен и включается фильтр направления.
    static let directionalMinSpeedKmh: Double = 10
    /// Камера считается «впереди», если отклонение от курса не больше этого угла (±).
    static let directionalMaxAngle: Double = 70
    /// Половина сектора «прямо»: камера в ±этого от курса — впереди, не «сбоку».
    /// Широкая (координаты камер в базе смещены вбок от полосы на десятки метров).
    static let directionAheadDeadZone: Double = 40

    /// Скорость, с которой считаем «поездка началась» — стартуем Live Activity
    /// (iOS позволяет запускать её только пока приложение на переднем плане).
    static let liveActivityStartSpeedKmh: Double = 15

    /// Умный радиус: предупреждаем за N секунд до камеры, а не за фиксированные метры.
    /// На 110 км/ч радиус растёт до ~670 м, в городе остаётся базовым из настроек.
    static let alertLeadTimeSeconds: Double = 22
    /// Потолок динамического радиуса (метры).
    static let maxDynamicRadius: CLLocationDistance = 1000

    /// «Пройденной» камера считается только если траверз был ближе этого порога:
    /// GPS-шум + ширина проспекта + погрешность базы ≈ 80 м. Камеры с параллельных
    /// улиц (150+ м) в статистику и штрафные оценки не попадают.
    static let passTraverseMaxMeters: CLLocationDistance = 80

    /// Гистерезис выхода из зоны оповещения: серия порогов сбрасывается только
    /// когда камера ушла заметно дальше радиуса — анти-дребезг на границе.
    static let alertExitHysteresisMeters: CLLocationDistance = 80

    /// Проезд считается завершённым, когда камера ушла дальше радиуса на этот запас
    /// (гарантирует, что траверз точно пройден, а не GPS-скачок).
    static let passReleaseHysteresisMeters: CLLocationDistance = 120

    /// Голос называет текущую скорость, только если едем быстрее этого порога.
    static let speakSpeedThresholdKmh: Double = 20

    // MARK: - Обновление базы камер (OTA)

    /// Сервер с актуальной базой. TODO: перейти на домен + HTTPS перед публикацией в App Store.
    static let syncBaseURL = URL(string: "http://45.130.148.94:8090")!

    /// Как часто автоматически проверять обновления базы.
    static let syncCheckInterval: TimeInterval = 24 * 60 * 60

    /// Версия базы, вшитой в приложение (Resources/cameras.json).
    /// v3 = данные портала data.egov.uz (1-008-0027) от 2026-07-10, 3341 точка.
    static let bundledDBVersion = 3

    /// Как часто опрашивать сервер о передвижных радарах (сек), пока приложение открыто.
    static let mobilePollInterval: TimeInterval = 180

    /// Через сколько секунд устойчивой остановки авто-завершать поездку (не гасим на светофоре).
    static let autoStopAfterSeconds: Double = 180

    /// Сколько секунд подряд активность «за рулём» (medium) должна держаться до автостарта.
    /// Отсекает ложные срабатывания пешком/в автобусе; high-уверенность стартует сразу.
    static let autoStartConfirmSeconds: Double = 8

    /// Коридор (метры) от линии маршрута — камеры ближе этого считаются «на маршруте».
    static let routeCorridorMeters: CLLocationDistance = 90

    // MARK: - Маршрутизация

    /// Наш OSRM-сервер (граф дорог OpenStreetMap): Apple Maps не строит
    /// автомобильные маршруты на территории Узбекистана, поэтому MKDirections —
    /// только первая попытка, при отказе едем через свой движок.
    static let osrmBaseURL = syncBaseURL.appendingPathComponent("osrm")

    /// Отклонение от линии маршрута (метры), после которого считаем «свернул не туда».
    static let rerouteDeviationMeters: CLLocationDistance = 150
    /// Сколько GPS-точек подряд должны быть вне маршрута, чтобы перестроить (защита от шума GPS).
    static let rerouteConfirmTicks = 3
    /// Не перестраивать маршрут чаще, чем раз в N секунд.
    static let rerouteCooldownSeconds: TimeInterval = 20
    /// Радиус прибытия: ближе этого до финиша — маршрут выполнен.
    static let arrivalRadiusMeters: CLLocationDistance = 60

    // MARK: - CarPlay

    /// До какого расстояния показывать ближайшую камеру в HUD машины.
    static let carPlayNearestCameraMeters: CLLocationDistance = 3000
    /// Обзорный зум карты CarPlay (широта, градусы): дальше камеры не рисуем —
    /// это уровень «вся область», маркеры сливаются.
    static let carPlayCameraZoomThreshold = 0.6
    /// Максимум маркеров камер на экране машины — водителю нужен обзор, не свалка.
    static let carPlayMaxCameraMarkers = 120
}
