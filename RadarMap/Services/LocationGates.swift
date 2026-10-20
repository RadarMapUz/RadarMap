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
        } else if camera.profileMayMute,
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

    /// Камера ЯВНО позади: едем с достоверным курсом, и она за спиной дальше
    /// `alertPassedBehindMeters`. Не глушит ничего (позади и так не звучит) —
    /// только говорит движку, что подъезд к ней закончен, и следующий
    /// (после разворота или круга) — новый. Без курса — false: по случайному
    /// курсу стоящей машины «проехали» не решается.
    static func isClearlyBehind(_ camera: Camera, in situation: Situation) -> Bool {
        guard isFilteringActive(situation) else { return false }
        return RoadCorridor.fix(from: situation.coordinate, course: situation.course,
                                to: camera.coordinate).along < -AppConfig.alertPassedBehindMeters
    }

    /// Камера ЯВНО впереди: тот же порог в другую сторону. Новый подъезд к
    /// проеханной камере — только так; камера маршрута, которую остаток по
    /// маршруту ещё держит «0 м» за спиной, впереди не оказывается (ревью 20.10:
    /// иначе после каждой камеры на маршруте звучало второе «0 метров»).
    static func isClearlyAhead(_ camera: Camera, in situation: Situation) -> Bool {
        guard isFilteringActive(situation) else { return false }
        return RoadCorridor.fix(from: situation.coordinate, course: situation.course,
                                to: camera.coordinate).along > AppConfig.alertPassedAheadMeters
    }

    /// Новый подъезд к проеханной камере: она явно впереди, И проходит гейт
    /// «наша дорога», И едем не ползком, И мы на СВОЕЙ дороге камеры — сбоку
    /// от её куска или от прямой по её оси не дальше её ширины с запасом
    /// (недоказанным сторонам — и дальняя проезжая часть). Одного «впереди
    /// по курсу» мало — на параллельной улице в 250 м, на развязке-клевере и
    /// на парковке у дороги курс тоже смотрит на камеру (ревью 20.10). Без
    /// куска и оси (треноги, свои) своя дорога — та, по которой мы мимо неё
    /// проехали: прямая через точку сближения по нашему курсу там.
    static func isReapproach(_ camera: Camera, in situation: Situation,
                             passLine: AlertEngine.PassLine?) -> Bool {
        guard situation.speedKmh >= AppConfig.voiceMinSpeedKmh,
              isClearlyAhead(camera, in: situation),
              isOnOurRoad(camera, in: situation, isOnRoute: false) else { return false }
        let offset = PassGeometry.ownRoadOffset(camera: camera, at: situation.coordinate)
            ?? passLine.map { PassGeometry.lineOffset(situation.coordinate, through: $0.coordinate,
                                                      bearing: $0.course) }
        guard let offset else { return true }
        return offset <= PassGeometry.reapproachLimit(for: camera)
    }

    /// Кандидат в ближайшие: по маршруту — остаток вдоль него и признак «на
    /// маршруте» для гейта; камера, уехавшая назад по маршруту дальше допуска,
    /// — уже не маршрутная: в движении она снова «как все» (по прямой и через
    /// гейты — маршрут с разворотом проходит её второй раз), стоя — не
    /// кандидат вовсе, как и раньше. nil — не кандидат.
    /// `announced` — о камере уже сказали: такая, уехавшая назад по
    /// маршруту, кандидатом не становится, пока движок не забудет серию
    /// (проехали → новый подъезд): иначе проеханная камера после разворота
    /// у самой камеры заслоняла бы следующую камеру маршрута (ревью 20.10).
    static func candidateDistance(straight: CLLocationDistance, routeRemaining: CLLocationDistance?,
                                  announced: Bool,
                                  in situation: Situation) -> (distance: CLLocationDistance, onRoute: Bool)? {
        guard let routeRemaining else { return (straight, false) }
        if routeRemaining > -AppConfig.routePassedToleranceMeters { return (max(0, routeRemaining), true) }
        return isFilteringActive(situation) && !announced ? (straight, false) : nil
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
