//
//  TimedTrack.swift
//  RadarMap
//
//  Подробный трек поездки со временем — для видео регистратора.
//
//  Трек в TripRecord упрощён (точка раз в 30+ м, потом Дуглас — Пекер) и без
//  времени: для итогов и карты этого хватает, а поставить кадр видео на
//  карту — нет. Регистратор BYD координат не пишет, только время и скорость
//  в кадре, поэтому кадр к месту привязывается по времени — и нужен трек,
//  где у каждой точки есть секунда.
//
//  Пишется только по настройке (по умолчанию выключено), лежит только на
//  телефоне (Documents/tracks/<id поездки>.csv), живёт TimedTrackStore
//  .keepDays дней и уходит с телефона только руками владельца — кнопкой
//  «Трек GPX» в карточке поездки.
//
//  Чистая логика — покрыта TimedTrackTests.
//

import Foundation
import os

nonisolated struct TimedPoint: Equatable, Sendable {
    let time: Date
    let lat: Double
    let lon: Double
    let speedKmh: Double
}

nonisolated enum TimedTrack {

    /// CSV в одну строку на точку: секунды Unix, широта, долгота, скорость.
    static func encode(_ points: [TimedPoint]) -> String {
        points.map {
            String(format: "%.1f,%.6f,%.6f,%.1f", $0.time.timeIntervalSince1970, $0.lat, $0.lon, $0.speedKmh)
        }.joined(separator: "\n")
    }

    static func decode(_ text: String) -> [TimedPoint] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: ",")
            guard parts.count == 4, let t = Double(parts[0]), let lat = Double(parts[1]),
                  let lon = Double(parts[2]), let speed = Double(parts[3]) else { return nil }
            return TimedPoint(time: Date(timeIntervalSince1970: t), lat: lat, lon: lon, speedKmh: speed)
        }
    }

    /// GPX 1.1 — его понимают JOSM, редакторы OSM и наш разбор видео.
    /// Без времени (старая поездка без подробного трека) точки идут без <time>.
    /// Опорная точка: проезд камеры — у него есть и время, и место, и этим
    /// кадр видео ставится на трек даже без подробного трека.
    struct Waypoint {
        let lat: Double
        let lon: Double
        let time: Date
        let name: String
    }

    static func gpx(name: String, points: [(lat: Double, lon: Double, time: Date?, speedKmh: Double)],
                    waypoints: [Waypoint] = []) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let escaped = name.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="RadarMap" xmlns="http://www.topografix.com/GPX/1/1">

        """
        for w in waypoints {
            let label = w.name.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            out += String(format: "<wpt lat=\"%.6f\" lon=\"%.6f\">", w.lat, w.lon)
                + "<time>\(iso.string(from: w.time))</time><name>\(label)</name></wpt>\n"
        }
        out += "<trk><name>\(escaped)</name><trkseg>\n"
        for p in points {
            out += String(format: "<trkpt lat=\"%.6f\" lon=\"%.6f\">", p.lat, p.lon)
            if let time = p.time { out += "<time>\(iso.string(from: time))</time>" }
            // Скорость в м/с — в расширении, без схемы: стандартные читатели
            // её пропустят, наш разбор видео — возьмёт.
            out += String(format: "<extensions><speed>%.2f</speed></extensions></trkpt>\n", p.speedKmh / 3.6)
        }
        out += "</trkseg></trk>\n</gpx>\n"
        return out
    }
}

/// Файлы подробных треков на телефоне.
nonisolated enum TimedTrackStore {
    /// Сколько дней хранить: видео с регистратора к этому времени уже
    /// перезаписано (карта на 128 ГБ — около трёх недель езды).
    static let keepDays = 30

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tracks", isDirectory: true)
    }

    static func url(for tripID: Double) -> URL {
        directory.appendingPathComponent(String(format: "%.0f.csv", tripID))
    }

    static func save(_ points: [TimedPoint], tripID: Double) {
        guard !points.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try TimedTrack.encode(points).write(to: url(for: tripID), atomically: true, encoding: .utf8)
        } catch {
            Log.trips.error("подробный трек не сохранён: \(error.localizedDescription, privacy: .public)")
        }
        prune(now: Date())
    }

    static func load(tripID: Double) -> [TimedPoint]? {
        guard let text = try? String(contentsOf: url(for: tripID), encoding: .utf8) else { return nil }
        let points = TimedTrack.decode(text)
        return points.isEmpty ? nil : points
    }

    /// Файлы старше keepDays — долой (имя файла = время старта поездки).
    static func prune(now: Date) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let limit = now.timeIntervalSince1970 - Double(keepDays) * 86400
        for name in names {
            guard let started = Double(name.replacingOccurrences(of: ".csv", with: "")),
                  started < limit else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// GPX-файл поездки во временной папке — для системного «Поделиться».
    /// Есть подробный трек — с секундами; нет — упрощённый трек без времени.
    static func gpxFile(for record: TripRecord) -> URL? {
        let timed = load(tripID: record.id)
        let points: [(lat: Double, lon: Double, time: Date?, speedKmh: Double)] =
            timed.map { $0.map { ($0.lat, $0.lon, $0.time, $0.speedKmh) } }
            ?? record.trackPoints.map { ($0.lat, $0.lon, nil, $0.speedKmh) }
        guard points.count >= 2 else { return nil }
        let stamp = ISO8601DateFormatter.string(from: record.startedAt, timeZone: .current,
                                                formatOptions: [.withFullDate, .withTime])
            .replacingOccurrences(of: ":", with: "-")
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("RadarMap-\(stamp).gpx")
        do {
            let anchors = record.passed.compactMap { pass -> TimedTrack.Waypoint? in
                guard let lat = pass.lat, let lon = pass.lon else { return nil }
                return TimedTrack.Waypoint(lat: lat, lon: lon, time: pass.date,
                                           name: String(format: "камера %d, %.0f км/ч",
                                                        pass.cameraID, pass.speedKmh))
            }
            try TimedTrack.gpx(name: "RadarMap \(stamp)", points: points, waypoints: anchors)
                .write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            Log.trips.error("GPX не записан: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
