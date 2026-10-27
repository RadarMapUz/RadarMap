//
//  TrafficDemo.swift
//  RadarMap
//
//  DEBUG-показ пробок 33H: `-trafficDemo` кладёт в TrafficService
//  синтетический будничный вечер Ташкента (фикстура
//  Resources/Debug/traffic_demo_tashkent.json — настоящие дороги OSM, уровни
//  выдуманы детерминированно: проспекты в обе стороны, из центра тяжелее,
//  одностороннее одной линией). Формат — now.json v1 и восьмая колонка
//  ТОЛЬКО ФИКСТУРЫ: 1 — ребро «обычно в это время» (как его дал бы профиль
//  33G), 0 — живое. «Обычно» проходит тот же порог показа, что у профиля
//  (`usualTrafficShowRatio`).
//  `-trafficDemoZoom 15` держит обзорную карту на этом масштабе без наклона —
//  снимки 13/15/17 не зависят ни от сервера, ни от автозума.
//  В релизную сборку не попадает (и фикстура исключена из Release).
//

#if DEBUG
import CoreLocation
import Foundation
import os

enum TrafficDemo {
    static let fixtureName = "traffic_demo_tashkent"

    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-trafficDemo") }

    /// Масштаб обзора из `-trafficDemoZoom Z`; nil — обычный обзор.
    static let zoom: Double? = {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-trafficDemoZoom"), index + 1 < args.count else { return nil }
        return Double(args[index + 1])
    }()

    /// Фикстура → живые рёбра (через настоящий разбор now.json) и «обычно».
    static func split(_ data: Data) -> (live: [TrafficEdge], usual: [TrafficProfile.UsualEdge])? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["edges"] as? [[Double]] else { return nil }
        var liveRows: [[Double]] = []
        var usual: [TrafficProfile.UsualEdge] = []
        for row in rows where row.count >= 7 && row[6] > 0 {
            if row.count >= 8, row[7] == 1 {
                let ratio = row[5] / row[6]
                guard ratio < AppConfig.usualTrafficShowRatio else { continue }
                usual.append(TrafficProfile.UsualEdge(
                    a: CLLocationCoordinate2D(latitude: row[0], longitude: row[1]),
                    b: CLLocationCoordinate2D(latitude: row[2], longitude: row[3]),
                    ratio: ratio, source: .model, modelKmh: row[6]))
            } else {
                liveRows.append(Array(row.prefix(7)))
            }
        }
        let body: [String: Any] = ["v": 1, "generated": Date().timeIntervalSince1970, "edges": liveRows]
        guard let liveData = try? JSONSerialization.data(withJSONObject: body),
              let live = TrafficSnapshot.decode(liveData) else { return nil }
        return (live.edges, usual)
    }

    static func fixture(bundle: Bundle = .main) -> Data? {
        guard let url = bundle.url(forResource: fixtureName, withExtension: "json") else {
            Log.network.error("пробки: фикстуры показа нет в сборке")
            return nil
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            Log.network.error("пробки: фикстура показа не читается — \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
#endif
