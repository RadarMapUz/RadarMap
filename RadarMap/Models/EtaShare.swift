//
//  EtaShare.swift
//  RadarMap
//
//  «Поделиться прибытием» — ссылка, по которой знакомый видит «будет
//  примерно в 18:40».
//
//  Приватно по построению, и это проверяется тестом: телефон отправляет
//  четыре поля — случайную ссылку, время прибытия, остаток пути и статус. Ни
//  точки, ни цели, ни устройства. Сервер держит это в памяти и гасит ссылку
//  сам (server/api.py, «Поделиться прибытием»). Отправка начинается, только
//  когда водитель действительно поделился, и заканчивается с маршрутом:
//  «на месте» или «больше не отслеживается».
//
//  Чистая логика; покрыто EtaShareTests.
//

import Foundation
import Security

nonisolated enum EtaShare {

    enum Status: String, Sendable {
        case driving, arrived, ended
    }

    /// Случайная ссылка: 128 бит, base64url без заполнения (22 знака).
    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Страница для знакомого.
    static func link(base: URL, token: String) -> URL {
        base.appendingPathComponent("api").appendingPathComponent("eta").appendingPathComponent(token)
    }

    /// Тело обновления — только эти четыре поля.
    static func payload(token: String, arrival: Date, remainingMeters: Double,
                        status: Status) -> [String: Any] {
        ["token": token,
         "eta": arrival.timeIntervalSince1970.rounded(),
         "left_m": Int(max(0, remainingMeters).rounded()),
         "status": status.rawValue]
    }

    /// Слать ли обновление в пути. До 19.10 — каждую минуту, даже стоя в
    /// пробке с тем же прибытием: радио будилось ради тех же байтов. Теперь
    /// — когда прибытие сдвинулось на минуту, остаток на полкилометра, или
    /// для «живости» ссылки (сервер гасит её через 2 ч без обновлений).
    static func shouldSend(lastArrival: Date?, lastRemaining: Double?, lastSentAt: Date?,
                           arrival: Date, remaining: Double, now: Date) -> Bool {
        guard let lastArrival, let lastRemaining, let lastSentAt else { return true }
        if now.timeIntervalSince(lastSentAt) >= AppConfig.etaShareKeepAliveSeconds { return true }
        if abs(arrival.timeIntervalSince(lastArrival)) >= AppConfig.etaShareArrivalStepSeconds { return true }
        return abs(remaining - lastRemaining) >= AppConfig.etaShareRemainingStepMeters
    }
}
