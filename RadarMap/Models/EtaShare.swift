//
//  EtaShare.swift
//  RadarMap
//
//  «Поделиться прибытием» — ссылка, по которой знакомый видит «будет
//  примерно в 18:40».
//
//  Приватно по построению, и это проверяется тестом: телефон отправляет
//  случайный ключ записи, адрес страницы, время прибытия, остаток пути и
//  статус. Ни точки, ни цели, ни устройства. Сервер держит это в памяти и
//  гасит ссылку сам (server/api.py, «Поделиться прибытием»). Отправка
//  начинается, только когда водитель действительно поделился, и
//  заканчивается с маршрутом: «на месте» или «больше не отслеживается».
//
//  Читать и писать — разные ключи (14.12): в ссылке только адрес — хэш
//  ключа записи, сам ключ не покидает телефон иначе как в теле POST. У кого
//  ссылка, тот видит, но не пишет: ни ложного «дома», ни чужого времени.
//
//  Чистая логика; покрыто EtaShareTests.
//

import CryptoKit
import Foundation
import Security

nonisolated enum EtaShare {

    enum Status: String, Sendable {
        case driving, arrived, ended
    }

    /// Случайный ключ: 128 бит, base64url без заполнения (22 знака). Из него
    /// делается ключ записи; до 14.12 он же был ссылкой.
    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        }
        return base64url(Data(bytes))
    }

    /// Адрес страницы для ключа записи: base64url(SHA-256(ключ)) без «=», 43
    /// знака — тот же расчёт, что `eta_address` на сервере (общий вектор в
    /// тестах обеих сторон). Полный хэш, без обрезки: длина и есть метка
    /// «ссылка с ключом» — сервер не принимает голый token такой длины даже
    /// тогда, когда записи по адресу нет (семейная ссылка между поездками
    /// домой, рестарт сервиса), а старые сборки делали ссылки из 22 знаков.
    static func address(forKey key: String) -> String {
        base64url(Data(SHA256.hash(data: Data(key.utf8))))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Чем телефон пишет в ссылку.
    enum WriteKey: Equatable, Sendable {
        /// Ключ записи (14.12) — только на телефоне; в ссылке — его хэш.
        case secret(String)
        /// Ссылка до 14.12: адрес и есть ключ. Так пишет только семейная
        /// ссылка, созданная раньше, — до своей смены (30 дней).
        case legacy(String)

        /// Адрес страницы — то, что видит близкий в ссылке.
        var address: String {
            switch self {
            case .secret(let key): EtaShare.address(forKey: key)
            case .legacy(let token): token
            }
        }
    }

    /// Токен для проверки сервера: правильной формы, но ничей — страница
    /// ответит «ссылка устарела», ничего не создав.
    static let probeToken = String(repeating: "A", count: 22)

    /// Показывает ли сервер страницы ссылок. Страница прибытия — всегда HTML,
    /// и на устаревший токен тоже; 404 не-HTML — адреса нет: сервер старше
    /// функции. Так было 20.10: ссылка ушла знакомому и открылась
    /// `{"error": "not found"}`. Остальное (5xx, сбой) — не знаем.
    static func linkSupport(status: Int, contentType: String?) -> Bool? {
        if contentType?.lowercased().hasPrefix("text/html") == true { return true }
        if status == 404 { return false }
        return nil
    }

    /// Пора ли спросить сервер снова: «умеет» — раз в сутки, «не умеет» или
    /// не знаем — через 10 мин.
    static func probeDue(support: Bool?, lastProbe: Date?, now: Date) -> Bool {
        guard let lastProbe else { return true }
        let age = now.timeIntervalSince(lastProbe)
        return age >= (support == true ? AppConfig.etaShareProbeOKSeconds : AppConfig.etaShareProbeRetrySeconds)
    }

    /// Страница для знакомого.
    static func link(base: URL, token: String) -> URL {
        base.appendingPathComponent("api").appendingPathComponent("eta").appendingPathComponent(token)
    }

    /// Тело обновления — только эти поля. С ключом записи рядом идёт и сам
    /// адрес (`token`): сервер до 14.12 ключа не знает и пишет по token —
    /// ссылка работает и там (без защиты, как раньше); новый сервер пишет
    /// только по ключу и проверяет, что token — его адрес. Так телефону не
    /// нужно знать версию сервера, и выкладка посреди поездки ничего не ломает.
    static func payload(write: WriteKey, arrival: Date, remainingMeters: Double,
                        status: Status) -> [String: Any] {
        var body: [String: Any] = [
            "token": write.address,
            "eta": arrival.timeIntervalSince1970.rounded(),
            "left_m": Int(max(0, remainingMeters).rounded()),
            "status": status.rawValue,
        ]
        if case .secret(let key) = write { body["key"] = key }
        return body
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
