//
//  TrafficLinesTests.swift
//  RadarMapTests
//
//  Пробки на карте линиями улиц (33H): рёбра одного направления сшиваются,
//  встречное направление не сливается, короткая «зебра» сглаживается, толщина
//  одна на улицу, «стоят» — из скорости. И главное — ни одно ребро не теряется
//  и не рисуется дважды (длина сохраняется).
//

import CoreLocation
import Foundation
import Testing
@testable import RadarMap

@Suite("Пробки линиями улиц (33H)")
struct TrafficLinesTests {

    private let base = CLLocationCoordinate2D(latitude: 41.3000, longitude: 69.2800)

    /// Точка в `north` м к северу и `east` м к востоку от базы.
    private func at(_ north: Double, _ east: Double = 0) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: base.latitude + north / 111_320,
                               longitude: base.longitude + east / (111_320 * cos(base.latitude * .pi / 180)))
    }

    private func edge(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, level: Int = 1,
                      kmh: Double = 50, model: Double = 60,
                      source: TrafficEdge.Source = .live) -> TrafficEdge {
        TrafficEdge(a: a, b: b, level: level, kmh: kmh, modelKmh: model, source: source)
    }

    /// Улица на север из отрезков по `step` м с уровнями `levels`.
    private func street(_ levels: [Int], step: Double = 100, east: Double = 0,
                        model: Double = 60) -> [TrafficEdge] {
        levels.enumerated().map { index, level in
            edge(at(Double(index) * step, east), at(Double(index + 1) * step, east), level: level,
                 kmh: level == 3 ? 15 : 50, model: model)
        }
    }

    @Test("Отрезки одного уровня — одна линия, точки не дублируются")
    func straightChainIsOneLine() {
        let lines = TrafficLines.lines(from: street([2, 2, 2]))
        #expect(lines.count == 1)
        #expect(lines.first?.coordinates.count == 4)
        #expect(abs((lines.first?.length ?? 0) - 300) < 1)
    }

    @Test("Порядок рёбер в файле не важен")
    func orderDoesNotMatter() {
        let edges = street([1, 1, 1, 1])
        #expect(TrafficLines.lines(from: edges.reversed()).count == 1)
    }

    @Test("Встречные направления улицы — две линии, разворот не сшивается")
    func oppositeDirectionsStaySeparate() {
        let forward = street([1, 1])
        let backward = forward.map { edge($0.b, $0.a) }
        let lines = TrafficLines.lines(from: forward + backward)
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.coordinates.count == 3 })
    }

    @Test("Смена уровня режет линию")
    func levelChangeSplits() {
        let lines = TrafficLines.lines(from: street([1, 1, 3, 3]))
        #expect(lines.map(\.level) == [1, 3])
    }

    @Test("Короткий кусок другого уровня внутри улицы — уровень соседей")
    func shortBlipIsSmoothed() {
        let edges = [edge(at(0), at(100), level: 2), edge(at(100), at(200), level: 2),
                     edge(at(200), at(240), level: 3, kmh: 15),               // 40 м пробки
                     edge(at(240), at(340), level: 2), edge(at(340), at(440), level: 2)]
        let lines = TrafficLines.lines(from: edges)
        #expect(lines.count == 1, "зебра из 40 м снята: \(lines.map(\.level))")
        #expect(lines.first?.level == 2)
    }

    @Test("Длинный кусок другого уровня остаётся")
    func longPieceIsKept() {
        let lines = TrafficLines.lines(from: street([2, 3, 2]))        // 100 м пробки
        #expect(lines.map(\.level) == [2, 3, 2])
    }

    @Test("Короткий кусок на конце улицы не сглаживается — соседа с той стороны нет")
    func blipAtTheEndIsKept() {
        var edges = street([2, 2])
        edges.append(edge(at(200), at(230), level: 3, kmh: 15))
        #expect(TrafficLines.lines(from: edges).map(\.level) == [2, 3])
    }

    @Test("Разные соседи — короткий кусок остаётся: это граница, а не шум")
    func differentNeighboursKeepTheBlip() {
        var edges = street([1])
        edges.append(edge(at(100), at(140), level: 2))
        edges.append(edge(at(140), at(240), level: 3, kmh: 15))
        #expect(TrafficLines.lines(from: edges).map(\.level) == [1, 2, 3])
    }

    @Test("На перекрёстке улица идёт прямо, поперечная — своей линией")
    func crossingPrefersStraight() {
        let main = street([1, 1])
        let turn = edge(at(100), at(100, 100))          // поворот направо из середины
        let lines = TrafficLines.lines(from: main + [turn])
        #expect(lines.count == 2)
        #expect(lines.contains { $0.coordinates.count == 3 }, "основная улица не разорвана поворотом")
    }

    @Test("Слияние двух входов: присоединяется тот, что входит прямее")
    func mergeTakesTheStraighterInput() {
        let out = edge(at(100), at(200))
        let straight = edge(at(0), at(100))
        let slanted = edge(at(60, -25), at(100))       // ~32° сбоку — в пороге сшивки
        let lines = TrafficLines.lines(from: [slanted, out, straight])
        #expect(lines.count == 2)
        let long = lines.first { $0.coordinates.count == 3 }
        #expect(long?.coordinates.first.map { abs($0.longitude - base.longitude) < 1e-9 } == true)
    }

    @Test("Пробка медленнее 10 км/ч — «стоят»")
    func standstillIsTheFourthLevel() {
        #expect(TrafficLines.displayLevel(edge(at(0), at(100), level: 3, kmh: 6)) == 4)
        #expect(TrafficLines.displayLevel(edge(at(0), at(100), level: 3, kmh: 14)) == 3)
        #expect(TrafficLines.displayLevel(edge(at(0), at(100), level: 2, kmh: 4)) == 2,
                "«медленно» по отношению к графу не становится «стоят» на улице с графом 8 км/ч")
    }

    @Test("Модель и водители — разные линии, источник по умолчанию — водители")
    func sourceSplits() {
        var edges = street([1, 1])
        edges.append(edge(at(200), at(300), source: .usual))
        edges.append(edge(at(300), at(400), source: .usual))
        let lines = TrafficLines.lines(from: edges)
        #expect(lines.map(\.source) == [.live, .usual])
        #expect(TrafficEdge(a: base, b: base, level: 1, kmh: 1, modelKmh: 1).source == .live)
    }

    @Test("Толщина одна на улицу: скорость графа колеблется — класс общий")
    func oneTierPerStreet() {
        var edges = street([1, 3], model: 55)
        edges.append(edge(at(200), at(300), level: 1, kmh: 40, model: 45))
        let lines = TrafficLines.lines(from: edges)
        #expect(lines.count == 3)
        #expect(Set(lines.map(\.tier)).count == 1)
    }

    @Test("Повтор ребра и нулевое ребро — не линии")
    func duplicatesAndZeroEdgesAreIgnored() {
        let edges = street([1, 1]) + [street([1])[0], edge(at(500), at(500))]
        let lines = TrafficLines.lines(from: edges)
        #expect(lines.count == 1)
        #expect(abs((lines.first?.length ?? 0) - 200) < 1)
    }

    @Test("Кольцо (круговое движение) — замкнутая линия, ни одно ребро не потеряно")
    func ringIsClosed() {
        let corners = [at(0), at(0, 50), at(50, 50), at(50)]
        let ring = (0..<4).map { edge(corners[$0], corners[($0 + 1) % 4]) }
        // На кольце повороты по 90° — круче порога; кольцо из плавных дуг:
        let smooth = (0..<12).map { k -> TrafficEdge in
            func p(_ i: Int) -> CLLocationCoordinate2D {
                let angle = Double(i) / 12 * 2 * .pi
                return at(40 * sin(angle), 40 * cos(angle))
            }
            return edge(p(k), p((k + 1) % 12))
        }
        #expect(TrafficLines.lines(from: ring).count == 4)
        let lines = TrafficLines.lines(from: smooth)
        #expect(lines.count == 1)
        #expect(lines.first?.coordinates.count == 13)
    }

    @Test("Фикстура вечернего Ташкента: длина сохраняется, результат детерминирован")
    func fixtureConservesLength() throws {
        let url = try #require(Bundle.main.url(forResource: "traffic_demo_tashkent", withExtension: "json"))
        let snapshot = try #require(TrafficSnapshot.decode(Data(contentsOf: url)))
        let lines = TrafficLines.lines(from: snapshot.edges)
        let edgeLength = snapshot.edges.reduce(0.0) {
            $0 + GeoMath.fastDistance($1.a.latitude, $1.a.longitude, $1.b.latitude, $1.b.longitude)
        }
        let lineLength = lines.reduce(0.0) { $0 + $1.length }
        #expect(abs(edgeLength - lineLength) / edgeLength < 0.001, "рёбер \(edgeLength) м, линий \(lineLength) м")
        #expect(lines.count * 3 < snapshot.edges.count, "сшивка: \(lines.count) линий из \(snapshot.edges.count) рёбер")
        #expect(Set(lines.map(\.level)) == [1, 2, 3, 4])
        #expect(Set(lines.map(\.source)) == [.live], "now.json всегда живой: лишняя колонка не делает «обычно»")
        #expect(TrafficLines.lines(from: snapshot.edges) == lines)
    }

    @Test("Живое и «обычно» одним слоем: то же ребро — только живое")
    func liveBeatsUsualOnTheSameEdge() async {
        let live = street([3, 3])
        let usual = street([1, 1, 1]).map {
            TrafficProfile.UsualEdge(a: $0.a, b: $0.b, ratio: 0.5, source: .model, modelKmh: 60)
        }
        let lines = await TrafficLines.build(live: live, usual: usual)
        #expect(lines.map(\.source) == [.live, .usual])
        #expect(lines.first?.level == 3)
        #expect(lines.last?.level == 2, "«обычно» 0,5 графа — «медленно», теми же порогами, что живые")
        #expect(abs((lines.last?.length ?? 0) - 100) < 1, "под живыми рёбрами «обычно» не дублируется")
    }

    @Test("Показ: фикстура делится на живые и «обычно» с порогом профиля")
    func demoSplitsTheFixture() throws {
        let url = try #require(Bundle.main.url(forResource: "traffic_demo_tashkent", withExtension: "json"))
        let parts = try #require(TrafficDemo.split(Data(contentsOf: url)))
        #expect(!parts.live.isEmpty && !parts.usual.isEmpty)
        #expect(parts.usual.allSatisfy { $0.ratio < AppConfig.usualTrafficShowRatio })
        let lines = TrafficLines.lines(from: parts.live + TrafficLines.edges(usual: parts.usual))
        #expect(Set(lines.map(\.source)) == [.live, .usual])
    }

    @Test("Сглаживание: проход через один, соседний участок решает следующий проход")
    func smoothingSettles() {
        var values = [1, 2, 1, 2, 1]
        TrafficLines.smooth(&values, lengths: [100, 20, 20, 20, 100])
        #expect(values == [1, 1, 1, 1, 1])
    }
}
