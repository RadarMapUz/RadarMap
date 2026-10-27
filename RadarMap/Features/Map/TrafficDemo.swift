//
//  TrafficDemo.swift
//  RadarMap
//
//  DEBUG-показ пробок 33H: `-trafficDemo` кладёт в TrafficService
//  синтетический now.json будничного вечера Ташкента (фикстура
//  Resources/Debug/traffic_demo_tashkent.json — настоящие дороги OSM, уровни
//  и источник выдуманы детерминированно: проспекты в обе стороны, из центра
//  тяжелее, одностороннее одной линией, второстепенные — «модель»).
//  `-trafficDemoZoom 15` держит обзорную карту на этом масштабе без наклона —
//  снимки 13/15/17 не зависят ни от сервера, ни от автозума.
//  В релизную сборку не попадает (и фикстура исключена из Release).
//

#if DEBUG
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
