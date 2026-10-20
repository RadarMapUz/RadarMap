//
//  UsageStats.swift
//  RadarMap
//
//  Обезличенный суточный агрегат использования.
//
//  Зачем он вообще нужен: MetricKit собирает ТЕХНИЧЕСКОЕ здоровье — крэши,
//  зависания, время запуска. Продуктового не собирается ничего, и сегодня
//  нельзя ответить ни на один вопрос, от которого зависят все решения. Сколько
//  людей доходит до конца онбординга. Сколько выдаёт геолокацию «Всегда» — а
//  без неё не работают ни фоновые оповещения, ни автостарт поездки, то есть
//  половина продукта. Сколько вообще совершает первую поездку. Без этих цифр
//  «сделать удобно и полезно» — это гадание.
//
//  Что здесь есть и чего здесь нет — важнее самих полей:
//
//    • НЕТ ни одной координаты, ни одного маршрута, ни одного адреса, ни
//      одного времени события. Только счётчики за сутки и суммы.
//    • Идентификатор — тот же ротируемый раз в 30 дней UUID, что у остальных
//      сервисов: связать сутки в длинный след нельзя дольше месяца.
//    • Выключается в настройках и гасится пультом (features.metrics).
//
//  Это ровно то, что честно декларируется в App Privacy как «Usage Data, не
//  связано с личностью», и ни байтом больше.
//

import Foundation

nonisolated struct UsageStats: Codable, Equatable, Sendable {
    /// День, за который собраны счётчики (yyyy-MM-dd в календаре устройства).
    var day: String

    // --- воронка: главные цифры продукта ---
    /// Онбординг пройден.
    var onboarded: Bool = false
    /// Уровень разрешения геолокации на момент отчёта.
    var locationAuth: String = "notDetermined"
    /// Уведомления разрешены (без них не работают фоновые оповещения).
    var notificationsAllowed: Bool = false

    // --- что человек делал за сутки ---
    var trips = 0
    var kilometres = 0.0
    var alerts = 0
    var passes = 0
    var reports = 0
    /// Сколько раз открывали экраны. Счётчики, а не события: «когда и в каком
    /// порядке» — это уже след поведения, и он нам не нужен.
    var screens: [String: Int] = [:]

    // MARK: - Качество решений, а не только их количество
    //
    // Приложение принимает за поездку тысячи решений, и до сих пор в отчёт
    // попадало только их ЧИСЛО. Поэтому пять дефектов пришли от водителя, а не
    // из телеметрии: по счётчику «алертов 12» нельзя понять, были ли они
    // правдой (docs/plan_algorithms.md, А3).
    //
    // Ни координат, ни времени события — только суточные суммы, как и всё
    // остальное здесь.

    /// Откуда взялся лимит у ЗАПИСАННОГО проезда: `tag` — из базы,
    /// `assumed` — выведен по классу дороги, `none` — лимита не было вовсе.
    /// Проезд выбран точкой отсчёта не случайно: именно из него растут деньги,
    /// рейтинг и тишина, то есть цена ошибки.
    var limitSource: [String: Int] = [:]

    /// Какие манёвры произносились: `right`, `roundabout`, `arrive`…
    /// Этот счётчик поймал бы «поверните направо» на прямой дороге за день.
    var maneuvers: [String: Int] = [:]

    /// Почему поездка не сохранилась: `short`, `merged`, `notDriver`,
    /// `crashShort`. Жалоба «одну поездку не засчитал» без этого неразрешима.
    var tripsDropped: [String: Int] = [:]

    /// Охват предупреждений (`AlertRecall`): `passed` — камер проехали,
    /// `warned` — о скольких сказали заранее, `late` — сказали уже вплотную,
    /// `silent` — промолчали, `unused` — сказали о камере, мимо которой так и
    /// не проехали.
    ///
    /// Это первая цифра, по которой на вопрос «умно ли работает алгоритм»
    /// можно ответить не рассуждением. Суточные суммы, как и всё остальное
    /// здесь: ни координаты камеры, ни времени, ни её идентификатора.
    var alertRecall: [String: Int] = [:]

    /// Сколько фраз о камерах прозвучало ВСЛУХ и насколько многословных:
    /// `brief`, `calm`, `urgent`.
    ///
    /// Не то же самое, что `alerts`. Тот считает срабатывания — баннер и тук,
    /// — и их девятнадцать на поездку. Вслух приложение говорит далеко не
    /// всегда: своя камера молчит, пробка откладывает, «Молча» выключает
    /// голос целиком. Жалоба же была именно про голос, и до сих пор про него
    /// не было ни одной цифры.
    var voiced: [String: Int] = [:]

    /// Сколько раз за сутки система просила освободить память.
    ///
    /// Телеметрия показала 73 фоновых завершения по памяти за сорок суток, и
    /// увидеть их можно было только через MetricKit — то есть постфактум и не
    /// глядя. Счётчик здесь делает частоту видимой рядом с остальными:
    /// «вылетает» перестаёт быть ощущением.
    var memoryWarnings = 0

    /// Экран машины за сутки: `sessions`, `minutes`, фризы главного потока
    /// (`hitches` > 250 мс, `longHitches` > 1 с, `maxHitchMs`). Жалоба «на
    /// CarPlay км/ч и кнопки не работают» приходит из машины, где лог не
    /// прочесть; эти суммы отвечают, был ли это фриз телефона.
    ///
    /// Опционал — не небрежность: синтезированный Codable требует каждый
    /// необязательный ключ, и файл статистики, записанный прежней сборкой, без
    /// этого поля не прочитался бы — сутки счётчиков пропали бы при обновлении.
    var carPlay: [String: Int]?

    /// Пустой отчёт слать незачем: приложение просто не открывали.
    var isEmpty: Bool {
        // День с одной лишь сессией машины (зависло — поездка не началась) —
        // как раз тот, ради которого счётчики CarPlay заведены.
        trips == 0 && alerts == 0 && passes == 0 && reports == 0 && screens.isEmpty
            && (carPlay?.isEmpty ?? true)
    }

    static func today(calendar: Calendar = .current, now: Date = Date()) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// Что накопилось и что уже готово к отправке. Отдельный тип, потому что за
/// сутки может смениться несколько дней (телефон не открывали неделю), и
/// «текущий» день нельзя путать с очередью на отправку.
nonisolated struct UsageStatsFile: Codable, Sendable {
    var current: UsageStats
    /// Готовые дни, ещё не ушедшие на сервер. Держим немного: статистика
    /// недельной давности ничего не решает, а очередь расти вечно не должна.
    var pending: [UsageStats] = []

    static let pendingCap = 7
}

/// Чтение с пропусками: поля, добавленные в новых сборках (limitSource,
/// alertRecall, voiced, memoryWarnings…), отсутствуют в файле старой сборки —
/// и синтезированный разбор выбрасывал весь файл: сегодняшние счётчики и до
/// семи неотправленных дней (сценарий S16, правило 18). Нет поля — значение
/// по умолчанию.
extension UsageStats {
    // nonisolated: тип nonisolated, и разбор файла не должен требовать main.
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(day: try c.decode(String.self, forKey: .day))
        onboarded = try c.decodeIfPresent(Bool.self, forKey: .onboarded) ?? onboarded
        locationAuth = try c.decodeIfPresent(String.self, forKey: .locationAuth) ?? locationAuth
        notificationsAllowed = try c.decodeIfPresent(Bool.self, forKey: .notificationsAllowed) ?? notificationsAllowed
        trips = try c.decodeIfPresent(Int.self, forKey: .trips) ?? trips
        kilometres = try c.decodeIfPresent(Double.self, forKey: .kilometres) ?? kilometres
        alerts = try c.decodeIfPresent(Int.self, forKey: .alerts) ?? alerts
        passes = try c.decodeIfPresent(Int.self, forKey: .passes) ?? passes
        reports = try c.decodeIfPresent(Int.self, forKey: .reports) ?? reports
        screens = try c.decodeIfPresent([String: Int].self, forKey: .screens) ?? screens
        limitSource = try c.decodeIfPresent([String: Int].self, forKey: .limitSource) ?? limitSource
        maneuvers = try c.decodeIfPresent([String: Int].self, forKey: .maneuvers) ?? maneuvers
        tripsDropped = try c.decodeIfPresent([String: Int].self, forKey: .tripsDropped) ?? tripsDropped
        alertRecall = try c.decodeIfPresent([String: Int].self, forKey: .alertRecall) ?? alertRecall
        voiced = try c.decodeIfPresent([String: Int].self, forKey: .voiced) ?? voiced
        memoryWarnings = try c.decodeIfPresent(Int.self, forKey: .memoryWarnings) ?? memoryWarnings
        carPlay = try c.decodeIfPresent([String: Int].self, forKey: .carPlay)
    }
}
