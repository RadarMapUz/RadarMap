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

    /// Одна поездка в выгрузке «все сразу»: свой трек и свои опорные точки.
    struct Trip {
        let name: String
        let points: [(lat: Double, lon: Double, time: Date?, speedKmh: Double)]
        let waypoints: [Waypoint]
    }

    static func gpx(name: String, points: [(lat: Double, lon: Double, time: Date?, speedKmh: Double)],
                    waypoints: [Waypoint] = []) -> String {
        gpx(trips: [Trip(name: name, points: points, waypoints: waypoints)])
    }

    /// Несколько поездок в одном файле: каждая — свой <trk>, опорные точки
    /// всех поездок — в начале (так требует порядок элементов GPX 1.1).
    /// Поездка без линии (у старых записей её не хранят) — только опоры.
    static func gpx(trips: [Trip]) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="RadarMap" xmlns="http://www.topografix.com/GPX/1/1">

        """
        for w in trips.flatMap(\.waypoints) {
            out += String(format: "<wpt lat=\"%.6f\" lon=\"%.6f\">", w.lat, w.lon)
                + "<time>\(iso.string(from: w.time))</time><name>\(escape(w.name))</name></wpt>\n"
        }
        for trip in trips where !trip.points.isEmpty {
            out += "<trk><name>\(escape(trip.name))</name><trkseg>\n"
            for p in trip.points {
                out += String(format: "<trkpt lat=\"%.6f\" lon=\"%.6f\">", p.lat, p.lon)
                if let time = p.time { out += "<time>\(iso.string(from: time))</time>" }
                // Скорость в м/с — в расширении, без схемы: стандартные
                // читатели её пропустят, наш разбор видео — возьмёт.
                out += String(format: "<extensions><speed>%.2f</speed></extensions></trkpt>\n",
                              p.speedKmh / 3.6)
            }
            out += "</trkseg></trk>\n"
        }
        out += "</gpx>\n"
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
            // Посекундный трек — самое точное, что есть о передвижениях
            // человека: в резервную копию iCloud он не идёт (S10, 20.10).
            var folder = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            try TimedTrack.encode(points).write(to: url(for: tripID), atomically: true, encoding: .utf8)
        } catch {
            Log.trips.error("подробный трек не сохранён: \(error.localizedDescription, privacy: .public)")
        }
        prune(now: Date())
    }

    static func load(tripID: Double) -> [TimedPoint]? {
        // Файла нет — трек старше keepDays уже вычищен (prune), это штатно.
        guard let text = try? String(contentsOf: url(for: tripID), encoding: .utf8) else { return nil }
        let points = TimedTrack.decode(text)
        return points.isEmpty ? nil : points
    }

    /// Файлы старше keepDays — долой (имя файла = время старта поездки).
    /// Зовётся и на запуске: с выключенным «Подробным треком» записей нет, и
    /// чистка при записи не наступала — треки жили вечно (S10, 20.10).
    static func prune(now: Date) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            Log.trips.error("подробные треки не перечислены: \(error.localizedDescription, privacy: .public)")
            return
        }
        let limit = now.timeIntervalSince1970 - Double(keepDays) * 86400
        for name in names {
            guard let started = Double(name.replacingOccurrences(of: ".csv", with: "")),
                  started < limit else { continue }
            removeFile(directory.appendingPathComponent(name))
        }
    }

    /// Трек одной поездки — удалили поездку, удаляется и он.
    static func remove(tripID: Double) {
        removeFile(url(for: tripID))
    }

    /// Все треки — «Удалить все поездки».
    static func removeAll() {
        removeFile(directory)
    }

    private static func removeFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Log.trips.error("подробный трек не удалён: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// GPX-файл поездки во временной папке — для системного «Поделиться».
    /// Есть подробный трек — с секундами; нет — упрощённый трек без времени.
    static func gpxFile(for record: TripRecord) -> URL? {
        let trip = trip(of: record)
        guard trip.points.count >= 2 else { return nil }
        return write(TimedTrack.gpx(trips: [trip]), name: "RadarMap-\(stamp(record.startedAt)).gpx")
    }

    /// Все поездки истории одним файлом. У старых записей линии нет (её не
    /// хранят дольше недели) — тогда в файл идут только проезды камер.
    static func gpxFile(forAll records: [TripRecord]) -> URL? {
        let trips = records.sorted { $0.startedAt < $1.startedAt }.map(trip(of:))
            .filter { !$0.points.isEmpty || !$0.waypoints.isEmpty }
        guard !trips.isEmpty else { return nil }
        return write(TimedTrack.gpx(trips: trips), name: "RadarMap-все-поездки-\(stamp(Date())).gpx")
    }

    /// Поездка для GPX: подробный трек со временем, если он ещё лежит, иначе
    /// упрощённый без времени; опоры — проезды камер. Её же берёт экспорт.
    static func trip(of record: TripRecord) -> TimedTrack.Trip {
        let timed = load(tripID: record.id)
        let points: [(lat: Double, lon: Double, time: Date?, speedKmh: Double)] =
            timed.map { $0.map { ($0.lat, $0.lon, $0.time, $0.speedKmh) } }
            ?? record.trackPoints.map { ($0.lat, $0.lon, nil, $0.speedKmh) }
        let anchors = record.passed.compactMap { pass -> TimedTrack.Waypoint? in
            guard let lat = pass.lat, let lon = pass.lon else { return nil }
            return TimedTrack.Waypoint(lat: lat, lon: lon, time: pass.date,
                                       name: String(format: "камера %d, %.0f км/ч",
                                                    pass.cameraID, pass.speedKmh))
        }
        return TimedTrack.Trip(name: "RadarMap \(stamp(record.startedAt))", points: points,
                               waypoints: anchors)
    }

    private static func stamp(_ date: Date) -> String {
        ISO8601DateFormatter.string(from: date, timeZone: .current,
                                    formatOptions: [.withFullDate, .withTime])
            .replacingOccurrences(of: ":", with: "-")
    }

    private static func write(_ text: String, name: String) -> URL? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            Log.trips.error("GPX не записан: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
