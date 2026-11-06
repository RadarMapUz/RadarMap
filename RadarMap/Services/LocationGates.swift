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
        /// Погрешность фикса: на плохом GPS допуск расширяется, а не сужается
        /// (кусок дороги и коридор, 14.14), и доказательства по месту нет.
        /// ≤ 0 — неизвестна: считаем худшей принятой (`fixAccuracy`).
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

    /// Ответ гейтов вместе с причиной. «Наша или нет» — по-прежнему `isOurs`,
    /// причина нужна охвату предупреждений (AlertRecall): тишина о камере,
    /// которую гейт ДОКАЗАННО отнёс к чужой дороге (встречный двойник,
    /// поперечная улица), — верная тишина, а не промах. Эвристика (коридор) и
    /// «позади» доказательством не считаются.
    enum Verdict: Equatable {
        /// Наша: маршрут, своя проезжая часть впереди, коридор.
        case ours
        /// Гейты выключены — стоим или курса нет. В пользу предупреждения.
        case unfiltered
        /// Доказано: едем против направления односторонней проезжей части, и
        /// стороны поделены (Camera.allowsDirectionGate).
        case provenDirection
        /// Доказано: едем поперёк оси её дороги — мост или поперечная улица.
        case provenAxis
        /// Доказано: вне её проезжей части по куску дороги, стороны поделены.
        case provenOffCarriageway
        /// На её проезжей части, но камера позади.
        case behind
        /// Вне коридора нашей дороги — эвристика, не доказательство.
        case outsideCorridor

        /// Тот самый ответ `isOnOurRoad`.
        var isOurs: Bool { self == .ours || self == .unfiltered }

        /// Доказано ли, что камера не наша: true — доказано, false — нет
        /// (наша, позади, эвристика), nil — гейты воздержались (стоим, курса
        /// нет): о дороге этот тик не говорит ничего.
        var provenNotOurs: Bool? {
            switch self {
            case .unfiltered: return nil
            case .provenDirection, .provenAxis, .provenOffCarriageway: return true
            case .ours, .behind, .outsideCorridor: return false
            }
        }
    }

    /// Камера «наша»: подтверждена маршрутом, либо мы на её проезжей части, либо
    /// она лежит в коридоре нашей дороги впереди. Вся политика — в `verdict`;
    /// здесь только ответ «да/нет», один на оба вызова (второй копии гейтов нет).
    ///
    /// - Parameter isOnRoute: камера лежит на построенном маршруте. Ответ
    ///   приходит снаружи, потому что маршрут принадлежит `RouteService`, а
    ///   гейт обязан оставаться функцией от геометрии.
    static func isOnOurRoad(_ camera: Camera, in situation: Situation,
                            isOnRoute: Bool) -> Bool {
        verdict(camera, in: situation, isOnRoute: isOnRoute).isOurs
    }

    /// Вердикт гейтов с причиной. Коридор (`RoadCorridor`) считает боковое
    /// отклонение в метрах и отсекает параллельные улицы, дублёры и эстакады,
    /// которые прежний угловой фильтр пропускал (±70° на дистанции 400 м — это
    /// 375 м вбок).
    ///
    /// Порядок здесь и есть политика: сначала прямые доказательства «наша», и
    /// только потом эвристики, которые вправе глушить.
    static func verdict(_ camera: Camera, in situation: Situation,
                        isOnRoute: Bool) -> Verdict {
        guard isFilteringActive(situation) else { return .unfiltered }

        // 1. Камера на активном маршруте — она на нашем пути по определению, и
        // никакая геометрия этого не отменяет: координата в реестре бывает
        // смещена вбок от полосы. Раньше проверка стояла ПОСЛЕ геометрии, и та
        // успевала заглушить камеру на собственном маршруте пользователя.
        // Исключение одно (27.J): доказанно встречная камера коридора сюда
        // приходит уже с isOnRoute = false (routeRemaining, RouteCamera.
        // countsAsOurs) — её судят шаги ниже, как любую камеру вне маршрута.
        // Камера за концом линии (позади старта) в маршрут не попадает вовсе
        // (RouteLineEnds) — её судят так же.
        if isOnRoute { return .ours }

        let coordinate = situation.coordinate
        let shape = RoadShape(camera: camera)
        let accuracy = fixAccuracy(situation)

        // 2. НАПРАВЛЕНИЕ проезжей части — самый однозначный признак, но применять
        // его можно не везде: часть камер снимает И обратную сторону дороги, и
        // для них молчание опаснее лишнего предупреждения. Гейт включается
        // только там, где стороны заведомо поделены между двумя камерами или
        // дорога не разделена вовсе (см. Camera.sidesAreProven).
        //
        // Направление, ось и «вне её проезжей части» ниже — всё это профиль
        // дороги камеры, и глушить по нему можно, только если ему верят
        // (`profileMayMute`): не снап на проезд или тротуар и не камера с
        // непроверенной позицией (needsReview — профиль бывает поперечной
        // улицы, 14.13). Такие камеры доходят до щедрого коридора (шаг 4).
        if camera.allowsDirectionGate, let direction = camera.dir {
            if GeoMath.angleDifference(situation.course, Double(direction))
                > AppConfig.cameraDirectionMaxAngle {
                return .provenDirection
            }
        } else if camera.profileMayMute,
                  let axis = shape?.axis(near: coordinate) ?? camera.axis.map(Double.init) {
            // Ось дороги камеры против курса: едем поперёк — это мост НАД камерой
            // или перпендикулярная улица развязки. Боковое отклонение тут ноль,
            // коридор бессилен — различает только направление. Ось берём с куска
            // дороги, если он есть: на кривой единственная ось всей дороги врёт.
            if GeoMath.axisDifference(course: situation.course, axis: axis)
                > AppConfig.cameraAxisMaxAngle {
                return .provenAxis
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
                + max(AppConfig.roadShapeMinToleranceMeters, accuracy)
            // Камера может снимать обе стороны разделённой дороги — тогда «своей»
            // для неё считается и обратная проезжая часть. В OSM каждая сторона
            // отдельная линия, и без этого запаса мы едем в 10–40 м от её куска
            // дороги и глушим камеру, которая нас как раз и снимает.
            if !camera.sidesAreProven { allowed += AppConfig.dividedRoadSpanMeters }
            if lateral <= allowed { return isAhead(camera, in: situation) ? .ours : .behind }
            // Мы не на дороге камеры — но глушить вправе только там, где стороны
            // доказанно поделены. Иначе решает коридор.
            //
            // И только по годному фиксу (14.14): «не на её проезжей части» —
            // это различение проезжих частей, а они в 10–40 м друг от друга
            // (`dividedRoadSpanMeters`). Фикс хуже `courseProofMaxAccuracyMeters`
            // сам может стоять на соседней, и расширить допуск на его
            // погрешность мало: погрешность — радиус, а не граница, и в
            // каньоне точка держится сдвинутой в одну сторону, — каждый тик
            // такой «точности сверх заявленной» глушил бы камеру весь подъезд.
            // Порог тот же, что у остальных доказательств (запись проезда,
            // охват, курс по земле): охват такие вердикты и так не считал.
            // Хуже порога решает коридор — эвристика, расширенная той же
            // погрешностью: параллельная улица в сотне метров остаётся чужой.
            if camera.sidesAreProven, accuracy <= AppConfig.courseProofMaxAccuracyMeters {
                return .provenOffCarriageway
            }
        }

        // 4. Коридор — эвристика для всего остального: куска дороги нет (старая
        // база, снап не нашёл дорогу) или он кончился раньше нас.
        // Внезапным точкам (краудсорс) — коридор трассы: их координату ставил
        // человек на ходу. Камерам с непроверенной позицией (needsReview: снап
        // не нашёл её дорогу) — тоже: лучше предупредить с запасом, чем
        // промолчать из-за смещённой координаты в реестре. Их профиль глушить
        // не вправе (шаги 2–3), так что решает этот коридор — или кусок
        // дороги, если он говорит «наша».
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
        // Коридор мерится от линии курса через НАШУ точку: на плохом фиксе он
        // шире на её погрешность (14.14) — иначе уверенный доплеровский курс
        // на точке в 40 м вбок выталкивал свою камеру из ближней зоны.
        return RoadCorridor.contains(camera: camera.coordinate, from: coordinate,
                                     course: situation.course, context: context,
                                     nearWidth: nearWidth, accuracy: accuracy) ? .ours : .outsideCorridor
    }

    /// Погрешность фикса для гейтов. Неизвестная (≤ 0) — как худшая, какую
    /// пропускает LocationFilter: неизвестность — в пользу предупреждения.
    /// С курсом такой фикс до гейтов не доходит (фильтр его отбрасывает, а
    /// курс и точность приходят с одного принятого фикса), так что это
    /// правило на случай, а не на каждый день.
    static func fixAccuracy(_ situation: Situation) -> CLLocationAccuracy {
        accuracyOrPoorest(situation.horizontalAccuracy)
    }

    /// Та же замена для любой точки (и для точки сближения у линии проезда).
    static func accuracyOrPoorest(_ accuracy: CLLocationAccuracy) -> CLLocationAccuracy {
        accuracy > 0 ? accuracy : AppConfig.maxHorizontalAccuracyMeters
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

    /// «Были у камеры» для серии ОПОВЕЩЕНИЯ (сценарий S4): ближе этого —
    /// траверз, после которого «явно позади» два фикса подряд значит
    /// «проехали», и следующий подъезд (разворот, круг) — новый; на тех же
    /// тиках снимается точка сближения линии проезда
    /// (`AlertEngine.noteApproach`). Шире записи проезда
    /// (`alertTraverseMeters`, 90 м): проезд по дальней проезжей части
    /// широкого проспекта тоже «был».
    ///
    /// Погрешность фикса (14.16) — по правилу коридора (14.14): сверх
    /// `corridorAccuracyBaselineMeters` траверз шире на
    /// `corridorAccuracyFactor` метров на метр. Расстояние меряется от НАШЕЙ
    /// точки: в каньоне (доплеровский курс уверенный, гейты работают)
    /// дальняя проезжая часть в 35 м плюс точка, уехавшая от дороги камеры
    /// ещё на свои 60 м, — это 95 м при пороге 90: камера не «проезжалась»,
    /// серия не закрывалась, и после разворота на её сторону (поправка 14.15
    /// там уже стояла) камера, снимающая обе стороны, молчала весь обратный
    /// подъезд.
    ///
    /// Сторона одна — к предупреждению: «проехали» само ничего не глушит,
    /// только разрешает новый подъезд (`isReapproach` со своей дорогой
    /// камеры). И камеру впереди проеханной это не делает: «проехали» по-
    /// прежнему ждёт «явно позади» (`isClearlyBehind`) два фикса подряд, то
    /// есть того, что сближение кончилось и расстояние растёт. Предел
    /// конечен: погрешность — не хуже худшей принятой
    /// (`maxHorizontalAccuracyMeters`, 65 м; неизвестная — как она), траверз
    /// не шире 90 + 55 = 145 м. На фиксе до 10 м — ровно прежние 90.
    ///
    /// Только для оповещения. Запись проезда (PassTracking), охват
    /// (`AlertRecall.notePassed`/`noteTraverse`) и доказательства у камеры
    /// (`isProvenOffRoad`, `isProvenCrossing`) меряют свой траверз —
    /// `PassGeometry.traverseLimit`, 40/80 м, — по доказательству, и
    /// погрешность фикса его не расширяет: там ошибка стоит ложного
    /// превышения, а не лишнего сигнала.
    static func alertTraverseLimit(for camera: Camera,
                                   accuracy: CLLocationAccuracy) -> CLLocationDistance {
        let bounded = min(accuracyOrPoorest(accuracy), AppConfig.maxHorizontalAccuracyMeters)
        // Не уже записи проезда: камера, чей проезд записан, для оповещения
        // тоже «была» (сегодня 90 м шире и 40, и 80).
        return max(PassGeometry.traverseLimit(for: camera), AppConfig.alertTraverseMeters)
            + RoadCorridor.accuracyAllowance(bounded)
    }

    /// Новый подъезд к проеханной камере: она явно впереди, И проходит гейт
    /// «наша дорога», И едем не ползком, И мы на СВОЕЙ дороге камеры — сбоку
    /// от её куска или от прямой по её оси не дальше её ширины с запасом
    /// (недоказанным сторонам — и дальняя проезжая часть). Одного «впереди
    /// по курсу» мало — на параллельной улице в 250 м, на развязке-клевере и
    /// на парковке у дороги курс тоже смотрит на камеру (ревью 20.10). Без
    /// куска и оси (треноги, свои) и у камеры с непроверенной позицией (её
    /// кусок бывает поперечной улицы, 14.13) своя дорога — та, по которой мы
    /// мимо неё проехали: прямая через точку сближения по нашему курсу там.
    ///
    /// Погрешность фикса (14.15) — по правилу коридора (14.14): сверх
    /// `corridorAccuracyBaselineMeters` предел своей дороги шире на
    /// `corridorAccuracyFactor` метров на метр. Смещение меряется от НАШЕЙ
    /// точки, и её погрешность ложится на него один к одному: после
    /// разворота в каньоне (доплеровский курс уверенный, гейты работают)
    /// встречная проезжая часть в 12 м плюс точка, уехавшая на свои 50 м, —
    /// это 62 м при пределе 50, и серия не забывалась: камера, снимающая обе
    /// стороны, молчала весь обратный подъезд. У линии проезда ошибается и
    /// вторая точка — точка сближения, снятая своим фиксом, — и запас нужен
    /// на обе. Почему не «на плохом фиксе доказательства нет — перевзводить»:
    /// тогда решал бы один `isOnOurRoad`, а на таком фиксе это коридор от
    /// НАШЕГО курса, расширенный на ту же погрешность, — с параллельной улицы
    /// в 120 м камеру в 400 м впереди он уже видит своей. Своя дорога
    /// меряется от дороги камеры (или линии проезда), и с запасом её предел
    /// остаётся конечным: на худшем принятом фиксе (65 м) — плюс 55 м от её
    /// дороги (плюс ещё 55 у линии проезда, если и сближение было на
    /// худшем), так что улица в 200 м своей не становится ни на каком фиксе.
    /// На хорошем GPS (до 10 м) — ровно прежний предел, и клевер без второго
    /// «первого» не тронут; на плохом петля клевера может перевзвести камеру —
    /// лишнее предупреждение, цена правила асимметрии.
    static func isReapproach(_ camera: Camera, in situation: Situation,
                             passLine: AlertEngine.PassLine?) -> Bool {
        guard situation.speedKmh >= AppConfig.voiceMinSpeedKmh,
              isClearlyAhead(camera, in: situation),
              isOnOurRoad(camera, in: situation, isOnRoute: false) else { return false }
        var slack = RoadCorridor.accuracyAllowance(fixAccuracy(situation))
        let offset: Double
        if let own = PassGeometry.ownRoadOffset(camera: camera, at: situation.coordinate) {
            offset = own
        } else if let passLine {
            offset = PassGeometry.lineOffset(situation.coordinate, through: passLine.coordinate,
                                             bearing: passLine.course)
            slack += RoadCorridor.accuracyAllowance(accuracyOrPoorest(passLine.accuracy))
        } else {
            return true
        }
        return offset <= PassGeometry.reapproachLimit(for: camera) + slack
    }

    /// Остаток по маршруту до камеры маршрута — или nil, когда прогрессу по
    /// маршруту верить нельзя, и камера идёт «как все»: по прямой и через
    /// гейты (сценарий S7).
    ///
    /// Нельзя в двух случаях. Съехали с линии (`isOffRoute`) — проекция
    /// застыла на старой дороге. И маршрут строится или перестраивается
    /// (`isProgressFrozen`): `RouteService.updateProgress` ждёт конца
    /// построения, `progressAlong` стоит там, где машина была до него, а
    /// машина едет дальше. Замена маршрута без сети серверным (12б.10) идёт
    /// по живой, ещё не вернувшейся связи — Apple, потом OSRM до 12 с, — и
    /// на 90 км/ч камера «через 800 м» оставалась такой полкилометра:
    /// предупреждение опаздывало, а проеханная за это время камера не
    /// звучала вовсе (ревью 14.2). Прямая короче дороги — предупреждение
    /// раньше, не позже.
    ///
    /// Доказанно встречная камера коридора (27.J, `RouteCameraDirection`) —
    /// тоже не маршрутная: «маршрут сильнее геометрии» про неё не говорит,
    /// её судят обычные гейты по живому фиксу, как любую камеру вне маршрута.
    ///
    /// - Parameter cameraAlong: где камера на линии маршрута; nil — камера
    ///   не на маршруте.
    /// - Parameter provenOncoming: камера коридора доказанно встречная для
    ///   линии маршрута (близнец, направление против курса линии).
    static func routeRemaining(cameraAlong: CLLocationDistance?, provenOncoming: Bool = false,
                               progressAlong: CLLocationDistance,
                               isOffRoute: Bool, isProgressFrozen: Bool) -> CLLocationDistance? {
        guard let cameraAlong, !provenOncoming, !isOffRoute, !isProgressFrozen else { return nil }
        return cameraAlong - progressAlong
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

    /// Кандидат в ближайшие: камера, расстояние (по маршруту или по прямой) и
    /// признак «на маршруте» для гейта.
    typealias Candidate = (camera: Camera, distance: CLLocationDistance, onRoute: Bool)

    /// Камера ПРЕДУПРЕЖДЕНИЯ: первая по расстоянию, которую гейты признали
    /// нашей. Ниже порога скорости гейты воздержались — тогда это просто
    /// ближайшая (неизвестность в пользу предупреждения). Показ может держать
    /// другую (`NearestDisplayHold`), этот выбор — никогда.
    static func nearestOursIndex(_ candidates: [Candidate], in situation: Situation) -> Int? {
        candidates.firstIndex { isOnOurRoad($0.camera, in: situation, isOnRoute: $0.onRoute) }
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
