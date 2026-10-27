//
//  TrafficCityScoreTests.swift
//  RadarMapTests
//
//  Балл пробок города и лист по касанию линии (33H). Главное: три медленных
//  проезда не делают «10 баллов» городу, «обычно» не становится десяткой
//  оттого, что профиль несёт только медленные рёбра, свободный участок не
//  добавляет «+0 мин», а «стоим» не превращается в бесконечное время.
//

import CoreLocation
import Foundation
import Testing
@testable import RadarMap

@Suite("Балл пробок города и лист по касанию (33H)")
struct TrafficCityScoreTests {

    /// Линия магистрали длиной `km` в центре Ташкента.
    private func line(_ km: Double, level: Int, source: TrafficEdge.Source = .live, tier: Int = 0,
                      at center: CLLocationCoordinate2D = .init(latitude: 41.311, longitude: 69.28)) -> TrafficLines.Line {
        TrafficLines.Line(coordinates: [center, CLLocationCoordinate2D(latitude: center.latitude + 0.001,
                                                                       longitude: center.longitude)],
                          level: level, source: source, tier: tier, length: km * 1000, kmh: 20, modelKmh: 60)
    }

    @Test("Свободный город — 0, город в пробке — 10")
    func extremes() {
        #expect(TrafficCityScore.score([line(30, level: 1)])?.value == 0)
        #expect(TrafficCityScore.score([line(30, level: 4)])?.value == 10)
        #expect(TrafficCityScore.score([line(30, level: 4)])?.usual == false)
    }

    @Test("Половина магистралей «медленно» — середина шкалы")
    func middle() throws {
        let score = try #require(TrafficCityScore.score([line(15, level: 1), line(15, level: 2)]))
        // c = 15·0,5 / 30 = 0,25; 10 · 0,25 / 0,66 ≈ 3,8 → 4.
        #expect(score.value == 4)
        #expect(score.level == 2)
    }

    @Test("Мало живых данных — не балл по ним: три проезда не говорят за город")
    func fewLiveDataIsNotAScore() {
        #expect(TrafficCityScore.score([line(3, level: 4)]) == nil)
    }

    @Test("Без живых — по «обычно» с пометкой; знаменатель — вся сеть магистралей")
    func usualFallback() throws {
        let score = try #require(TrafficCityScore.score([line(3, level: 4), line(200, level: 3, source: .usual)]))
        #expect(score.usual)
        // 200 км пробки из 1280 км сети: 10 · (200/1280) / 0,66 ≈ 2,4 → 2.
        #expect(score.value == 2, "профиль несёт только медленные рёбра — «обычно» не должно быть всегда десяткой")
    }

    @Test("Улицы и линии за городом в балл не идут")
    func onlyTashkentMajors() {
        let outside = CLLocationCoordinate2D(latitude: 39.65, longitude: 66.96)     // Самарканд
        #expect(TrafficCityScore.score([line(40, level: 4, tier: 1)]) == nil)
        #expect(TrafficCityScore.score([line(40, level: 4, at: outside)]) == nil)
    }

    @Test("Цвет балла: 0–3 свободно, 4–6 медленно, 7–10 пробка")
    func levelOfScore() {
        #expect(TrafficCityScore.Score(value: 3, usual: false).level == 1)
        #expect(TrafficCityScore.Score(value: 4, usual: false).level == 2)
        #expect(TrafficCityScore.Score(value: 7, usual: true).level == 3)
    }

    // MARK: - Лист по касанию

    @Test("Пробка 2,4 км на 12 км/ч при графе 60 — около +9,6 мин")
    func tapDelay() {
        let tap = TrafficTap(level: 3, usual: false, length: 2400, kmh: 12, modelKmh: 60)
        #expect(abs(tap.delay - (2400 / (12 / 3.6) - 2400 / (60 / 3.6))) < 0.5)
        #expect(tap.shownDelay != nil)
    }

    @Test("Свободно — без задержки; короткая задержка не печатается")
    func noDelayWhenFree() {
        #expect(TrafficTap(level: 1, usual: false, length: 2400, kmh: 30, modelKmh: 60).delay == 0)
        #expect(TrafficTap(level: 2, usual: false, length: 150, kmh: 30, modelKmh: 60).shownDelay == nil)
    }

    @Test("«Стоим» на 0 км/ч — конечное время, как на 3 км/ч")
    func standstillIsFinite() {
        let zero = TrafficTap(level: 4, usual: false, length: 500, kmh: 0, modelKmh: 60)
        let three = TrafficTap(level: 4, usual: false, length: 500, kmh: 3, modelKmh: 60)
        #expect(zero.delay.isFinite && zero.delay == three.delay)
    }

    @Test("Признаки линии карты → лист; без длины — не лист")
    func fromAttributes() throws {
        let tap = try #require(TrafficTap(attributes: ["level": NSNumber(value: 2), "src": NSNumber(value: 1),
                                                       "len": NSNumber(value: 800), "kmh": NSNumber(value: 25),
                                                       "model": NSNumber(value: 55)]))
        #expect(tap.level == 2 && tap.usual && tap.length == 800 && tap.modelKmh == 55)
        #expect(TrafficTap(attributes: ["level": NSNumber(value: 2)]) == nil)
    }
}
