//
//  AlertRecall.swift
//  RadarMap
//
//  Приложение наконец меряет собственную главную работу: о скольких камерах,
//  мимо которых человек физически проехал, оно успело сказать.
//
//  Зачем. За поездку конвейер принимает тысячи решений — предупредить или
//  промолчать, — и до сих пор наружу выходило только их ЧИСЛО («алертов 12»).
//  По этому числу нельзя отличить двенадцать правдивых предупреждений от
//  двенадцати про соседнюю улицу при трёх пропущенных камерах. Ровно это
//  зафиксировано в docs/plan_algorithms.md §0.4 как корневая слабость, и
//  именно поэтому все известные дефекты приехали от водителя, а не из цифр.
//
//  Что здесь считается и, главное, чего здесь НЕ считается.
//
//    • Знаменатель — камеры, мимо которых ПРОЕХАЛИ физически: траверз ближе
//      порога записи. Это наблюдение о географии, а не о решении конвейера,
//      поэтому оно не наследует ни гейтов, ни правил записи проезда — иначе
//      метрика проверяла бы сама себя и всегда давала бы сто процентов.
//    • Числитель — камеры, о которых предупреждение прозвучало ЗАРАНЕЕ.
//      Предупреждение, впервые прозвучавшее уже в зоне измерения (ближе 80 м),
//      считается отдельно: формально оно было, но сделать с ним человек уже
//      ничего не успевает, и записывать его в успех — врать себе.
//    • Причину молчания мы НЕ раскладываем по гейтам. Чтобы назвать виновный
//      гейт, `LocationGates.isOnOurRoad` должен был бы возвращать не «да/нет»,
//      а вердикт с причиной, — а это самая ответственная функция приложения,
//      и переписывать её ради счётчика нельзя. Пока честнее сказать «промолчал
//      о двух» и не выдумывать, почему.
//
//  Никаких координат и никакого времени: наружу уходят только суммы, как и всё
//  остальное в UsageStats.
//
//  Чистая логика — покрыта AlertRecallTests.
//

import CoreLocation

nonisolated struct AlertRecall {

    /// Итог: сколько камер проехали и сколько из них приложение назвало.
    struct Tally: Codable, Equatable, Sendable {
        /// Камер проехали физически.
        var passed = 0
        /// Из них предупредили заранее — до зоны измерения.
        var warned = 0
        /// Из них предупредили, но уже вплотную: поздно.
        var late = 0
        /// Из них не предупредили вовсе.
        var silent = 0
        /// Предупредили о камере, мимо которой так и не проехали. Само по себе
        /// это НЕ ошибка — свернул с дороги, объехал, — но рост этого числа
        /// относительно `passed` и есть «пугает зря».
        var unused = 0

        /// Доля распознанных приближений, 0…1. nil — проездов не было, и
        /// доля неопределена: ноль из нуля это не «ноль процентов».
        var recall: Double? {
            passed > 0 ? Double(warned) / Double(passed) : nil
        }

        var isEmpty: Bool { passed == 0 && unused == 0 }

        static func + (lhs: Tally, rhs: Tally) -> Tally {
            Tally(passed: lhs.passed + rhs.passed, warned: lhs.warned + rhs.warned,
                  late: lhs.late + rhs.late, silent: lhs.silent + rhs.silent,
                  unused: lhs.unused + rhs.unused)
        }
    }

    /// Дистанция ПЕРВОГО предупреждения по каждой камере. Именно первого:
    /// эскалация (уровни 2–3) звучит вплотную у любой камеры, и по последнему
    /// уровню всякое предупреждение выглядело бы запоздалым.
    private var firstAlertDistance: [Int: CLLocationDistance] = [:]
    /// Камеры, мимо которых проехали физически.
    private var passedIDs: Set<Int> = []

    init() {}

    /// Прозвучало предупреждение о камере.
    mutating func noteAlert(cameraID: Int, distance: CLLocationDistance) {
        guard firstAlertDistance[cameraID] == nil else { return }
        firstAlertDistance[cameraID] = distance
    }

    /// Предупредили ли об этой камере в поездке — для записи проезда (6.7):
    /// «промолчала» поднимает жалобу на экране проезда наверх.
    func wasAlerted(cameraID: Int) -> Bool { firstAlertDistance[cameraID] != nil }

    /// Проехали мимо камеры физически. Зовётся из наблюдения за геометрией,
    /// а не из записи проезда: у записи свои, намеренно более строгие гейты
    /// (ложный проезд стоит денег), и мерить ими охват было бы подтасовкой.
    mutating func notePassed(cameraID: Int) {
        passedIDs.insert(cameraID)
    }

    /// Итог поездки.
    func tally(lateBelowMeters: CLLocationDistance = AppConfig.passZoneMeters) -> Tally {
        var out = Tally()
        out.passed = passedIDs.count
        for id in passedIDs {
            guard let distance = firstAlertDistance[id] else { out.silent += 1; continue }
            if distance < lateBelowMeters { out.late += 1 } else { out.warned += 1 }
        }
        out.unused = firstAlertDistance.keys.filter { !passedIDs.contains($0) }.count
        return out
    }

    mutating func reset() {
        firstAlertDistance.removeAll()
        passedIDs.removeAll()
    }
}

extension AlertRecall.Tally {
    /// Поле, добавленное позже, не делает старый файл «битым» (ревью S9).
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        passed = try c.decodeIfPresent(Int.self, forKey: .passed) ?? 0
        warned = try c.decodeIfPresent(Int.self, forKey: .warned) ?? 0
        late = try c.decodeIfPresent(Int.self, forKey: .late) ?? 0
        silent = try c.decodeIfPresent(Int.self, forKey: .silent) ?? 0
        unused = try c.decodeIfPresent(Int.self, forKey: .unused) ?? 0
    }
}
