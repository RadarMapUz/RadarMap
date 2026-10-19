//
//  LocationGates.swift
//  RadarMap
//
//  Гейты «эта камера наша?» — самое ответственное решение в приложении.
//
//  Здесь живёт третья ступень пайплайна оповещений: после того как
//  `LocationFilter` признал фикс годным, но до того как `AlertEngine` решит,
//  пора ли говорить. Гейты отвечают на один вопрос — камера впереди на НАШЕЙ
//  дороге или на соседней улице, эстакаде, обратной проезжей части.
//
//  ГЛАВНОЕ ПРАВИЛО, ради которого этот файл выделен отдельно: **молчание про
//  настоящую камеру хуже лишнего предупреждения**. Каждый гейт вправе заглушить
//  камеру ТОЛЬКО при доказательстве, что она не наша; неизвестность — всегда в
//  пользу предупреждения. Шесть отдельных багов «почему промолчало» родились из
//  нарушения именно этого правила, и порядок проверок в `isOnOurRoad` — не
//  стилистика, а политика.
//
//  Почему модуль, а не метод сервиса. Раньше эти восемьдесят строк лежали
//  внутри `LocationService` на 1224 строки и читали шесть его свойств. Чтобы
//  проверить утверждение «камера с недоказанными сторонами не глушится по
//  направлению», нужно было поднять `CLLocationManager`, — то есть проверить
//  его было нельзя, и правило держалось на внимательности читателя. Теперь это
//  чистая функция от `Situation`, и у неё есть свой тест-файл: ровно тот
//  порядок, который ARCHITECTURE.md требует от всех движков пайплайна.
//

import CoreLocation

nonisolated enum LocationGates {

    /// Всё, что гейтам нужно знать о моменте. Ровно шесть чисел: если сюда
    /// захочется положить сервис — значит гейт перестал быть решением о
    /// геометрии и стал чем-то ещё.
    struct Situation {
        let coordinate: CLLocationCoordinate2D
        /// Курс, которому МОЖНО верить (см. LocationFilter). `-1` — курса нет.
        let course: CLLocationDirection
        let speedKmh: Double
        /// Погрешность фикса: на плохом GPS допуск расширяется, а не сужается.
        let horizontalAccuracy: CLLocationAccuracy
        /// Город или трасса — от этого зависит ширина коридора.
        let context: AlertPolicy.Context
    }

    /// Фильтр направления активен, когда едем достаточно быстро и GPS-курс
    /// достоверен. Стоим или курса нет — не фильтруем вообще: стоящая машина
    /// не «едет мимо» камеры, и глушить по случайному курсу нельзя.
    static func isFilteringActive(_ situation: Situation) -> Bool {
        situation.course >= 0 && situation.speedKmh >= AppConfig.directionalMinSpeedKmh
    }

    /// Камера «наша»: подтверждена маршрутом, либо мы на её проезжей части, либо
    /// она лежит в коридоре нашей дороги впереди. Коридор (`RoadCorridor`)
    /// считает боковое отклонение в метрах и отсекает параллельные улицы,
    /// дублёры и эстакады, которые прежний угловой фильтр пропускал (±70° на
    /// дистанции 400 м — это 375 м вбок).
    ///
    /// Порядок здесь и есть политика: сначала прямые доказательства «наша», и
    /// только потом эвристики, которые вправе глушить.
    ///
    /// - Parameter isOnRoute: камера лежит на построенном маршруте. Ответ
    ///   приходит снаружи, потому что маршрут принадлежит `RouteService`, а
    ///   гейт обязан оставаться функцией от геометрии.
    static func isOnOurRoad(_ camera: Camera, in situation: Situation,
                            isOnRoute: Bool) -> Bool {
        guard isFilteringActive(situation) else { return true }

        // 1. Камера на активном маршруте — она на нашем пути по определению, и
        // никакая геометрия этого не отменяет: координата в реестре бывает
        // смещена вбок от полосы. Раньше проверка стояла ПОСЛЕ геометрии, и та
        // успевала заглушить камеру на собственном маршруте пользователя.
        if isOnRoute { return true }

        let coordinate = situation.coordinate
        let shape = RoadShape(camera: camera)

        // 2. НАПРАВЛЕНИЕ проезжей части — самый однозначный признак, но применять
        // его можно не везде: часть камер снимает И обратную сторону дороги, и
        // для них молчание опаснее лишнего предупреждения. Гейт включается
        // только там, где стороны заведомо поделены между двумя камерами или
        // дорога не разделена вовсе (см. Camera.sidesAreProven).
        if camera.allowsDirectionGate, let direction = camera.dir {
            if GeoMath.angleDifference(situation.course, Double(direction))
                > AppConfig.cameraDirectionMaxAngle {
                return false
            }
        } else if camera.hasTrustedRoadProfile,
                  let axis = shape?.axis(near: coordinate) ?? camera.axis.map(Double.init) {
            // Ось дороги камеры против курса: едем поперёк — это мост НАД камерой
            // или перпендикулярная улица развязки. Боковое отклонение тут ноль,
            // коридор бессилен — различает только направление. Ось берём с куска
            // дороги, если он есть: на кривой единственная ось всей дороги врёт.
            if GeoMath.axisDifference(course: situation.course, axis: axis)
                > AppConfig.cameraAxisMaxAngle {
                return false
            }
        }

        // 3. Кусок проезжей части камеры — единственные твёрдые данные о её
        // дороге, поэтому он решает в ОБЕ стороны: попали в её ширину — камера
        // наша (осталось убедиться, что она впереди), не попали — не наша.
        // Допуск включает погрешность фикса: на плохом GPS проверка обязана
        // воздержаться, а не глушить камеру.
        if let shape, let lateral = shape.lateralOffset(from: coordinate) {
            var allowed = RoadGeometry.halfWidth(lanes: camera.lanes,
                                                 roadClass: camera.roadClass)
                + max(AppConfig.roadShapeMinToleranceMeters, situation.horizontalAccuracy)
            // Камера может снимать обе стороны разделённой дороги — тогда «своей»
            // для неё считается и обратная проезжая часть. В OSM каждая сторона
            // отдельная линия, и без этого запаса мы едем в 10–40 м от её куска
            // дороги и глушим камеру, которая нас как раз и снимает.
            if !camera.sidesAreProven { allowed += AppConfig.dividedRoadSpanMeters }
            if lateral <= allowed { return isAhead(camera, in: situation) }
            // Мы не на дороге камеры — но глушить вправе только там, где стороны
            // доказанно поделены. Иначе решает коридор.
            if camera.sidesAreProven { return false }
        }

        // 4. Коридор — эвристика для всего остального: куска дороги нет (старая
        // база, снап не нашёл дорогу) или он кончился раньше нас.
        // Внезапным точкам (краудсорс) — коридор трассы: их координату ставил
        // человек на ходу. Камерам с непроверенной позицией (needsReview: снап
        // не нашёл её дорогу) — тоже: лучше предупредить с запасом, чем
        // промолчать из-за смещённой координаты в реестре.
        let generous = camera.kind.isSudden || camera.needsReview == true
        let context: AlertPolicy.Context = generous ? .highway : situation.context
        // Ширина ближней зоны коридора — от реальной дороги, если она известна.
        // Пол по константе: коридор мерится от линии НАШЕГО курса, а её точность
        // ограничена GPS, поэтому уже 10 м делать нельзя. Узкую ширину даём
        // только доказанным сторонам: у камеры, снимающей обе, обратная полоса
        // сама по себе шире этой ширины.
        let knowsRoad = camera.cls != nil || camera.lanes != nil
        let narrow = knowsRoad && !generous && camera.sidesAreProven
        let nearWidth: CLLocationDistance? = narrow
            ? max(AppConfig.corridorMinNearMeters,
                  RoadGeometry.halfWidth(lanes: camera.lanes, roadClass: camera.roadClass))
            : nil
        return RoadCorridor.contains(camera: camera.coordinate, from: coordinate,
                                     course: situation.course, context: context,
                                     nearWidth: nearWidth)
    }

    /// Камера впереди по курсу (с тем же запасом «немного позади», что у
    /// коридора: на самом траверзе продольная составляющая шумит вокруг нуля).
    static func isAhead(_ camera: Camera, in situation: Situation) -> Bool {
        RoadCorridor.fix(from: situation.coordinate, course: situation.course,
                         to: camera.coordinate)
            .along >= -AppConfig.corridorBehindToleranceMeters
    }
}

/// Входы в геозоны до загрузки базы камер (сценарий S3, 20.10): по одному на
/// геозону, выход снимает вход — вошли и вышли, пока читалась база, значит
/// камера уже позади.
nonisolated struct RegionEnterQueue: Equatable, Sendable {
    private(set) var pending: [String] = []

    mutating func enter(_ regionID: String) {
        guard !pending.contains(regionID) else { return }
        pending.append(regionID)
    }

    mutating func exit(_ regionID: String) {
        pending.removeAll { $0 == regionID }
    }

    mutating func drain() -> [String] {
        defer { pending = [] }
        return pending
    }
}
