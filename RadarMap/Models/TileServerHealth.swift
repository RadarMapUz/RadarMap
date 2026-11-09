//
//  TileServerHealth.swift
//  RadarMap
//
//  Сервер карты лёг, а связь есть (S22, 20.10). Прежде «без связи» знал
//  только NWPathMonitor: сеть есть — стиль онлайн, тайлы не грузятся, карта
//  серая без объяснения, а скачанная область не бралась, хотя лежала на
//  телефоне. Теперь сторож тайлов отмечает исходы своих загрузок, и подряд
//  несколько отказов за короткое окно без единого успеха — «сервер карты
//  недоступен»: карта уходит на скачанную область (если машина в ней) и
//  плашка говорит правду. Первый же успех — снова онлайн.
//
//  Чистая логика, время — параметром; покрыто TileServerHealthTests.
//

import Foundation

nonisolated struct TileServerHealth: Sendable {
    private var failures: [Date] = []
    private(set) var isDown = false

    /// Отказ загрузки (сеть оборвала, сервер ответил 5xx). true — состояние
    /// сменилось на «недоступен».
    mutating func noteFailure(at now: Date) -> Bool {
        failures = failures.filter { now.timeIntervalSince($0) <= AppConfig.tileServerFailureWindowSeconds } + [now]
        guard !isDown, failures.count >= AppConfig.tileServerFailureThreshold else { return false }
        isDown = true
        return true
    }

    /// Тайл пришёл. true — состояние сменилось на «доступен».
    mutating func noteSuccess() -> Bool {
        failures = []
        guard isDown else { return false }
        isDown = false
        return true
    }

    /// Ответила ли проба: любой код до 400. Тело не важно, важен живой сервер.
    static func probeAnswered(status: Int?) -> Bool {
        guard let status else { return false }
        return status < 400
    }

    /// Пробный возврат к онлайну: с областью на телефоне онлайн-запросов нет,
    /// и узнать, что сервер ожил, иначе нечем.
    mutating func resetForProbe() {
        failures = []
        isDown = false
    }
}
