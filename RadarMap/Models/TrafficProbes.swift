//
//  TrafficProbes.swift
//  RadarMap
//
//  Куски следа поездки для пробок — с приватностью по построению.
//
//  Пробки считает сервер из следов многих водителей (server/traffic_build.py:
//  OSRM match → скорость на ребре дороги). Отсюда уходит только то, без чего
//  скорость участка не посчитать, и ничего сверх:
//    * кусок ~1 км, точки — широта, долгота, СЕКУНДЫ ОТ НАЧАЛА КУСКА, км/ч;
//      ни устройства, ни поездки, ни абсолютного времени — куски одного
//      водителя между собой не связаны;
//    * первые и последние 400 м поездки не уходят НИКОГДА: конец держится,
//      пока машина не отъедет от него на 400 м, а на финише недоотправленный
//      хвост выбрасывается — откуда выехали и куда приехали, сервер не знает;
//    * ничего ближе 300 м от дома, работы и сохранённых мест — и кусок на
//      таком месте рвётся, а не перепрыгивает его;
//    * границы кусков плавают (±20 %), чтобы по длине нельзя было склеить
//      соседние куски обратно в поездку.
//
//  Чистая логика без сети и часов (время — параметром), покрыта
//  TrafficProbesTests. Отправляет TrafficService.
//

import CoreLocation
import Foundation

nonisolated struct TrafficProbes: Sendable {

    /// Кусок для отправки: [[lat, lon, t, kmh]], t — секунды от первой точки.
    struct Piece: Equatable, Sendable, Encodable {
        let p: [[Double]]
    }

    private struct Fix: Sendable {
        let lat: Double
        let lon: Double
        let kmh: Double
        let time: Date
        /// Метры от старта поездки до этой точки.
        let along: Double
    }

    /// Места, рядом с которыми след не собирается (дом, работа, сохранённые).
    private var zones: [CLLocationCoordinate2D] = []
    private var active = false
    private var traveled: Double = 0
    private var last: Fix?
    private var lastKept: Fix?
    /// Собираемый кусок и куски, ждущие, пока машина отъедет от их конца.
    private var current: [Fix] = []
    private var held: [[Fix]] = []
    private var ready: [Piece] = []
    /// Когда кончился каждый готовый кусок — только на телефоне, на сервер
    /// не уходит: по нему старые куски не отправляются (S21, 20.10).
    private var readyEnds: [Date] = []
    /// Длина текущего куска до закрытия (плавает вокруг pieceMeters).
    private var targetLength: Double = AppConfig.trafficPieceMeters
    private var random: @Sendable () -> Double

    /// `random` — источник плавающей длины кусков; в тестах подставляется.
    init(random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.random = random
    }

    // MARK: - Поездка

    mutating func begin(zones: [CLLocationCoordinate2D]) {
        self.zones = zones
        active = true
        traveled = 0
        last = nil
        lastKept = nil
        current = []
        held = []
        nextTarget()
    }

    /// Конец поездки: всё, что ещё держится (последние ≥ 400 м) и собирается,
    /// выбрасывается — финиш не уходит никогда. Готовые куски остаются.
    mutating func finish() {
        active = false
        current = []
        held = []
        last = nil
        lastKept = nil
    }

    var isActive: Bool { active }

    /// Принятый фикс поездки. `kmh < 0` — скорости нет.
    mutating func add(lat: Double, lon: Double, kmh: Double, at time: Date) {
        guard active else { return }
        if let last {
            let step = GeoMath.fastDistance(last.lat, last.lon, lat, lon)
            // Скачок (туннель, потеря сигнала) — не путь: кусок рвётся.
            if step > AppConfig.trafficMaxStepMeters
                || time.timeIntervalSince(last.time) > AppConfig.trafficMaxGapSeconds {
                closeCurrent()
            }
            traveled += min(step, AppConfig.trafficMaxStepMeters)
        }
        let fix = Fix(lat: lat, lon: lon, kmh: kmh, time: time, along: traveled)
        last = fix
        releaseHeld()

        // Начало поездки не уходит.
        guard traveled >= AppConfig.trafficTrimMeters else { return }
        // Рядом с приватным местом — не собираем и рвём кусок.
        if isPrivate(lat: lat, lon: lon) {
            closeCurrent()
            return
        }
        // Прореживание: точка на 25 м или 5 с — серверу хватает, а
        // отправка не раздувается фиксами по метру.
        if let kept = lastKept,
           GeoMath.fastDistance(kept.lat, kept.lon, lat, lon) < AppConfig.trafficSampleMeters,
           time.timeIntervalSince(kept.time) < AppConfig.trafficSampleSeconds {
            return
        }
        current.append(fix)
        lastKept = fix
        if let first = current.first,
           fix.along - first.along >= targetLength
            || fix.time.timeIntervalSince(first.time) >= AppConfig.trafficPieceMaxSeconds
            || current.count >= AppConfig.trafficPieceMaxPoints {
            closeCurrent()
        }
    }

    /// Готовые куски (и очистка очереди).
    mutating func takeReady() -> [Piece] {
        takeReadyStamped().map(\.piece)
    }

    /// Готовые куски с временем конца (локальным).
    mutating func takeReadyStamped() -> [(piece: Piece, endedAt: Date)] {
        defer { ready = []; readyEnds = [] }
        return Array(zip(ready, readyEnds)).map { (piece: $0.0, endedAt: $0.1) }
    }

    // MARK: - Внутреннее

    private mutating func closeCurrent() {
        if current.count >= AppConfig.trafficPieceMinPoints {
            held.append(current)
        }
        current = []
        lastKept = nil
        nextTarget()
    }

    /// Кусок отпускается, когда машина отъехала от его конца на 400 м: если
    /// поездка кончится раньше, его конец мог оказаться финишем.
    private mutating func releaseHeld() {
        while let piece = held.first, let end = piece.last,
              traveled - end.along >= AppConfig.trafficTrimMeters {
            held.removeFirst()
            ready.append(Self.encode(piece))
            readyEnds.append(end.time)
        }
    }

    private mutating func nextTarget() {
        let jitter = AppConfig.trafficPieceJitter
        targetLength = AppConfig.trafficPieceMeters * (1 - jitter + 2 * jitter * random())
    }

    private func isPrivate(lat: Double, lon: Double) -> Bool {
        zones.contains {
            GeoMath.fastDistance($0.latitude, $0.longitude, lat, lon) < AppConfig.trafficPrivacyRadiusMeters
        }
    }

    /// Время — целые секунды от первой точки, строго по возрастанию: сервер
    /// отвергает кусок с повтором (на 180 км/ч две точки через 25 м
    /// округлялись бы в одну секунду).
    private static func encode(_ fixes: [Fix]) -> Piece {
        let start = fixes[0].time
        var previous = -1.0
        return Piece(p: fixes.map { fix in
            let t = max(previous + 1, fix.time.timeIntervalSince(start).rounded())
            previous = t
            return [(fix.lat * 1e5).rounded() / 1e5,
                    (fix.lon * 1e5).rounded() / 1e5,
                    t,
                    fix.kmh >= 0 ? fix.kmh.rounded() : -1]
        })
    }
}
