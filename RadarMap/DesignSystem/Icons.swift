//
//  Icons.swift
//  RadarMap
//
//  Словарь значков: один смысл — один символ (docs/plan_full_2026-10-19.md,
//  4.1). До 19.10 треугольник значил четыре вещи («Радар!», ДТП,
//  предупреждение, «громко» в онбординге), своя камера рисовалась тремя
//  разными значками, а «на месте» — то пальцем, то печатью (теперь пальцем:
//  печать с галочкой уже значит «в лимите» и достижения). Значок, который
//  меняет смысл от экрана к экрану, водитель перестаёт читать вовсе.
//
//  Правило заливки: в меню и барах — как в системе (здесь — залитые там, где
//  их уже ждёт рука), но один смысл не бывает то залитым, то контурным.
//

import Foundation

nonisolated enum Icon {
    /// Отметить передвижной радар («Радар!», меню, карточки) — тот же
    /// значок, что у маркера передвижного радара на карте.
    static let reportRadar = "dot.radiowaves.left.and.right"
    /// Опасность, предупреждение, ДТП — только они.
    static let hazard = "exclamationmark.triangle.fill"
    /// Своя камера: добавить, своя на карте.
    static let ownCamera = "plus.viewfinder"
    /// Камеры как счётчик («камер на маршруте», «проездов камер»).
    static let cameras = "camera.fill"
    /// «Мои места» — в баре, меню и настройках одинаково.
    static let myPlaces = "star.fill"
    /// Ответы о точке: стоит на месте / её больше нет / стоит не там — одна
    /// пара значков и для стационарных, и для передвижных.
    static let pointHere = "hand.thumbsup.fill"
    static let pointGone = "hand.thumbsdown.fill"
    static let pointMisplaced = "mappin.slash"
    /// Слой «Места» (заведения): не бензоколонка — заправки он не прячет.
    static let placesLayer = "storefront.fill"
    /// Слой «Дома» (объёмные здания) — рядом с «Местами» в одном списке,
    /// поэтому значки обязаны различаться (ревью 4.1).
    static let buildingsLayer = "building.2.fill"
    /// «Камер не найдено» — про камеры, а не про геопозицию.
    static let noCameras = "camera"

    // MARK: Меню на карте (20.10)

    /// Слой «Пробки»: машины бампер к бамперу. Не светофор — светофор на
    /// этой карте сам рисуется значком, и «светофоры» читались бы как слой
    /// светофоров.
    static let trafficLayer = "car.2.fill"
    /// Слой «Тротуары» (у человечка нет залитого варианта — он и так сплошной).
    static let sidewalksLayer = "figure.walk"
    /// Кнопки «+ / −» в колонке — сами эти кнопки, а не лупа: лупа на главном
    /// экране уже значит «Поиск».
    static let zoomButtons = "plus.forwardslash.minus"
    /// Сигнал у камеры (тумблер «Звук» — писк, не голос) и «Только сигнал»
    /// в машине. Не динамик: динамиком нарисована шкала голоса рядом, и два
    /// одинаковых динамика в одной карточке читались как один выключатель.
    static let alertSignal = "bell.fill"
    /// Вибрация у камеры — системный значок «вибро».
    static let vibration = "iphone.radiowaves.left.and.right"

    // MARK: Геопозиция

    /// «Нет сигнала GPS»: антенна без волн. Перечёркнутая стрелка геопозиции
    /// на плашке читалась как перечёркнутый самолёт (владелец, 21.10).
    static let noGPSSignal = "antenna.radiowaves.left.and.right.slash"
    /// Нет ДОСТУПА к геопозиции — системный значок служб геолокации; причина
    /// другая, чем у потерянного сигнала, и значок другой.
    static let noLocationAccess = "location.slash.fill"

    // MARK: «Итоги» (34b)
    //
    // Один смысл — один символ на всех экранах раздела: строка раздела,
    // «Сделать», шапка листа и пустое состояние берут значок отсюда. Все —
    // не новее iOS 17 (минимум приложения — iOS 18; проверено по
    // name_availability.plist, ItogiIconsTests держит, что символ есть).

    /// Штрафы — и возможные, и пришедшие: документ-постановление.
    static let fines = "doc.text.fill"
    /// Поездки периода: карта и список.
    static let trips = "map.fill"
    /// Обслуживание машины.
    static let maintenance = "wrench.and.screwdriver.fill"
    /// Смены такси (рабочие рейсы) — руль, не портфель: портфель — «на работу».
    static let shifts = "steeringwheel"
    /// Свои отметки и подтверждения других водителей.
    static let community = "person.2.fill"
    /// За всё время: пожизненные цифры и достижения.
    static let lifetime = "infinity"
    /// Архив поездок.
    static let archive = "archivebox.fill"
    /// Цель недели.
    static let goal = "target"
    /// Путь выше лимита вне камер.
    static let overLimit = "gauge.with.dots.needle.67percent"
    /// Резкие разгоны и торможения.
    static let smoothness = "waveform.path.ecg"
    /// Расходы: бензин / электричество (по машине водителя).
    static let fuel = "fuelpump.fill"
    static let charge = "bolt.fill"
    /// Разбор по поездкам.
    static let byTrips = "list.bullet"
    /// По дням: график и календарь месяца.
    static let byDays = "calendar"
    /// Выгрузка периода.
    static let export = "square.and.arrow.up"
    /// Журнал заправок и зарядок.
    static let journal = "book.closed.fill"
    /// Машина: профиль расходов («Машина и расходы»).
    static let car = "car.fill"

    /// Все символы раздела «Итоги» — для проверки (ItogiIconsTests: символ
    /// есть в системе) и листа-сетки DEBUG `-itogiIcons`. Новый значок в
    /// «Итогах» — сначала сюда.
    static let itogiSymbols: [String] = [
        fines, cameras, trips, maintenance, shifts, community, lifetime, archive, goal,
        trafficLayer, overLimit, smoothness, fuel, charge, byTrips, byDays, export, journal, car,
        "house.fill", "briefcase.fill", "hourglass", "clock.fill", "scope", "lightbulb.fill",
        "bell.fill", "arrow.triangle.merge", "info.circle.fill", "checkmark.shield.fill",
        "checkmark.seal.fill", "gauge.with.dots.needle.33percent", "gauge.with.dots.needle.100percent",
        "point.topleft.down.to.point.bottomright.curvepath", "flame.fill",
        "tablecells", "doc.richtext", "trash", "ellipsis.circle",
        "line.3.horizontal.decrease.circle", "envelope.badge", "chevron.right",
    ]
}
