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
