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
//      `passed` так и остаётся географией; из знаменателя доли (`ours`)
//      вычитается только доказанно верная тишина — пункт ниже.
//    • Числитель — камеры, о которых предупреждение прозвучало ЗАРАНЕЕ.
//      Предупреждение, впервые прозвучавшее уже в зоне измерения (ближе 80 м),
//      считается отдельно: формально оно было, но сделать с ним человек уже
//      ничего не успевает, и записывать его в успех — врать себе.
//    • Верная тишина — не промах. Мимо камеры встречной проезжей части или
//      поперечной улицы на перекрёстке проезжают вплотную, и молчать о ней —
//      правильно. Такая камера уходит из счёта охвата (`notOurs`), но только
//      когда гейт ДОКАЗАЛ, что она не наша, на каждом годном тике у самой
//      камеры (`LocationGates.Verdict.provenNotOurs`: направление при
//      доказанных сторонах, ось её дороги, её проезжая часть). Годный — в
//      движении, с курсом и на фиксе не хуже `courseProofMaxAccuracyMeters`.
//      Эвристика коридора, «позади», тики без курса и на плохом фиксе
//      доказательством не считаются — там тишина остаётся промахом. Число исключённых видно отдельно: иначе
//      метрику можно было бы подкрутить, ослабив собственные доказательства.
//      Остальную тишину по гейтам мы по-прежнему не раскладываем.
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
        /// Из них не предупредили вовсе — и не доказали, что камера не наша.
        var silent = 0
        /// Предупредили о камере, мимо которой так и не проехали. Само по себе
        /// это НЕ ошибка — свернул с дороги, объехал, — но рост этого числа
        /// относительно `passed` и есть «пугает зря».
        var unused = 0
        /// Из `passed`: промолчали, и гейт доказал, что камера не наша
        /// (встречный двойник, поперечная улица). Верная тишина — в долю
        /// охвата не входит, но считается, чтобы её рост был виден.
        var notOurs = 0

        /// Камеры нашей дороги, мимо которых проехали: знаменатель охвата.
        /// `warned + late + silent` в сумме дают ровно его.
        var ours: Int { max(0, passed - notOurs) }

        /// Доля распознанных приближений, 0…1. nil — проездов не было, и
        /// доля неопределена: ноль из нуля это не «ноль процентов».
        var recall: Double? {
            ours > 0 ? Double(warned) / Double(ours) : nil
        }

        var isEmpty: Bool { passed == 0 && unused == 0 }

        static func + (lhs: Tally, rhs: Tally) -> Tally {
            Tally(passed: lhs.passed + rhs.passed, warned: lhs.warned + rhs.warned,
                  late: lhs.late + rhs.late, silent: lhs.silent + rhs.silent,
                  unused: lhs.unused + rhs.unused, notOurs: lhs.notOurs + rhs.notOurs)
        }
    }

    /// Дистанция ПЕРВОГО предупреждения по каждой камере. Именно первого:
    /// эскалация (уровни 2–3) звучит вплотную у любой камеры, и по последнему
    /// уровню всякое предупреждение выглядело бы запоздалым.
    private var firstAlertDistance: [Int: CLLocationDistance] = [:]
    /// Камеры, мимо которых проехали физически.
    private var passedIDs: Set<Int> = []
    /// Вердикт гейтов у самой камеры (тики ближе порога траверза): true —
    /// на КАЖДОМ годном тике доказано, что она не наша; false — хоть на одном
    /// не доказано. Нет записи — годных тиков не было (стояли, курса не было).
    private var traverseProof: [Int: Bool] = [:]

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

    /// Вердикт гейтов на тике у самой камеры (`LocationGates.Verdict.provenNotOurs`).
    /// Доказательство обязано держаться на всём проезде: один тик «наша» —
    /// и тишина о ней снова промах. nil (гейты воздержались) не меняет ничего.
    mutating func noteTraverse(cameraID: Int, provenNotOurs: Bool?) {
        guard let provenNotOurs else { return }
        traverseProof[cameraID] = (traverseProof[cameraID] ?? true) && provenNotOurs
    }

    /// Что тик у самой камеры говорит о верной тишине: вердикт гейта — но
    /// только на годном фиксе. На фиксе уровня Wi-Fi курс по земле — шум, и
    /// «доказательство» по нему (ось, направление) спрятало бы из счёта
    /// настоящий промах: такой тик воздерживается (nil).
    static func traverseEvidence(_ verdict: LocationGates.Verdict,
                                 accuracy: CLLocationAccuracy) -> Bool? {
        accuracy <= AppConfig.courseProofMaxAccuracyMeters ? verdict.provenNotOurs : nil
    }

    /// Тишина о камере доказанно верная: не предупреждали, и гейт на каждом
    /// годном тике у неё сказал «не наша».
    private func isProvenNotOurs(_ id: Int) -> Bool {
        firstAlertDistance[id] == nil && traverseProof[id] == true
    }

    /// Итог поездки.
    func tally(lateBelowMeters: CLLocationDistance = AppConfig.passZoneMeters) -> Tally {
        var out = Tally()
        out.passed = passedIDs.count
        for id in passedIDs {
            guard let distance = firstAlertDistance[id] else {
                if isProvenNotOurs(id) { out.notOurs += 1 } else { out.silent += 1 }
                continue
            }
            if distance < lateBelowMeters { out.late += 1 } else { out.warned += 1 }
        }
        out.unused = firstAlertDistance.keys.filter { !passedIDs.contains($0) }.count
        return out
    }

    /// Камеры, мимо которых проехали без единого предупреждения, — для
    /// журнала конца поездки: по нему прогон в симуляторе (и разбор лога с
    /// телефона) называет промах по номеру, а не одной цифрой охвата.
    var silentIDs: [Int] {
        passedIDs.filter { firstAlertDistance[$0] == nil && !isProvenNotOurs($0) }.sorted()
    }
    /// Промолчали верно: гейт доказал, что камера не наша.
    var notOursIDs: [Int] { passedIDs.filter(isProvenNotOurs).sorted() }
    /// Предупреждали, а мимо не проехали (камера соседней улицы или свернули).
    var unusedIDs: [Int] { firstAlertDistance.keys.filter { !passedIDs.contains($0) }.sorted() }

    mutating func reset() {
        firstAlertDistance.removeAll()
        passedIDs.removeAll()
        traverseProof.removeAll()
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
        notOurs = try c.decodeIfPresent(Int.self, forKey: .notOurs) ?? 0
    }
}
