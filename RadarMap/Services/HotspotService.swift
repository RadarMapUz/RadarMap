//
//  HotspotService.swift
//  RadarMap
//
//  Загрузка горячих точек треног: подписанный hotspots.json рядом с
//  version.json, раз в неделю. Список меняется медленно — кластеры копятся
//  месяцами, — и ежедневный запрос ради него был бы расходом батареи без
//  пользы.
//
//  Fail closed, как и всё, что применяется без участия пользователя: нет
//  подписи, чужой ключ, испорченный JSON, незнакомая версия контракта —
//  живём вообще без подсказок. Подсказка о треноге не стоит того, чтобы
//  доверять неподписанным данным (ARCHITECTURE.md, правило 19).
//
//  Кэш на диске поднимается сразу при старте: подсказки нужны за рулём, а
//  там связи может не быть вовсе.
//

import Foundation
import Observation
import CoreLocation
import os

@MainActor
@Observable
final class HotspotService {
    /// Действующий список. До первой удачной загрузки — пусто.
    private(set) var spots: [TripodHotspots.Spot] = []

    @ObservationIgnored private let api = APIClient(timeout: 10, resourceTimeout: 30)
    @ObservationIgnored private var isRefreshing = false

    private static var cacheURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hotspots.json")
    }

    init() {
        // Кэш проверяем той же подписью, что и загрузку: файл в Documents
        // доступен из бэкапа и файлового менеджера, так что «своё» на диске
        // ничем не надёжнее пришедшего по сети.
        if let envelope = JSONFile.load(SignedPayload<TripodHotspots>.self,
                                        from: Self.cacheURL, log: Log.network),
           let payload = envelope.verified(), payload.isUsable {
            spots = payload.spots
        }
    }

    /// Тихая проверка — не чаще раза в неделю.
    func refreshIfNeeded() async {
        let last = Storage.double(.hotspotsLastCheck)
        if last > 0, Date().timeIntervalSince1970 - last < AppConfig.hotspotRefreshInterval {
            return
        }
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let envelope = try await api.get("hotspots.json",
                                             as: SignedPayload<TripodHotspots>.self)
            guard let payload = envelope.verified(), payload.isUsable else {
                // Подпись не сошлась или контракт чужой: подсказки гасим целиком.
                // Половина списка хуже пустого — она выглядит как знание.
                Log.network.error("горячие точки: подпись или контракт не сошлись — подсказок не будет")
                spots = []
                JSONFile.remove(at: Self.cacheURL, log: Log.network)
                Storage.set(Date().timeIntervalSince1970, for: .hotspotsLastCheck)
                return
            }
            spots = payload.spots
            JSONFile.save(envelope, to: Self.cacheURL, log: Log.network)
            Storage.set(Date().timeIntervalSince1970, for: .hotspotsLastCheck)
            Log.network.info("горячие точки: \(payload.spots.count, privacy: .public)")
        } catch {
            // Сети нет — живём на кэше. Дату проверки не двигаем: попробуем
            // при следующем запуске, а не через неделю.
            Log.network.debug("горячие точки не обновились: \(error.localizedDescription, privacy: .public)")
        }
    }

    #if DEBUG
    /// Скриншот-хук `-demoHotspots`: две точки рядом с водителем. Только в
    /// памяти и без записи на диск — подписанного файла на симуляторе нет, а
    /// подделывать его нельзя даже ради снимка экрана.
    func seedDemo(near coordinate: CLLocationCoordinate2D) {
        spots = [
            TripodHotspots.Spot(lat: coordinate.latitude + 0.0045,
                                lon: coordinate.longitude + 0.0012,
                                n: 7, days: 5, peak: 1),
            TripodHotspots.Spot(lat: coordinate.latitude - 0.0030,
                                lon: coordinate.longitude - 0.0040,
                                n: 4, days: 3, peak: -1),
        ]
    }
    #endif

    /// Настройка выключена — данные не нужны ни в памяти, ни на диске.
    func clear() {
        guard !spots.isEmpty else { return }
        spots = []
        JSONFile.remove(at: Self.cacheURL, log: Log.network)
    }
}
