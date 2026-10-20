//
//  FamilyLink.swift
//  RadarMap
//
//  «Близкие видят прибытие» (план 19.10, 12б.6): одна постоянная ссылка для
//  одного человека — «Мама» видит «будет дома примерно в 18:40», когда
//  водитель едет домой, и «сейчас не в пути» всё остальное время.
//
//  Правила — здесь, чистые и с тестами (FamilyLinkTests):
//    * ссылку отправляет сам водитель, один раз (iOS не шлёт сообщения
//      молча); живая она только в поездке ДОМОЙ — по направлению призрака
//      дороги (Commute), то есть по своей истории: в магазин, к друзьям, на
//      работу — «сейчас не в пути»;
//    * на сервере — только адрес и, пока едем, четыре поля «Поделиться
//      прибытием», в памяти. Никакой позиции: время прибытия и «в пути /
//      дома». Ссылка меняется каждые 30 дней — долгоживущий идентификатор
//      человека не копится; новую ссылку водитель пересылает сам;
//    * в ссылке — адрес, хэш ключа записи (14.12); ключ — только здесь, так
//      что ни близкий, ни тот, кому он переслал ссылку, «дома» не пришлёт;
//    * пауза в один тап — на эту поездку; выключатель — в настройках.
//

import Foundation

nonisolated struct FamilyLink: Codable, Equatable, Sendable {
    /// Адрес страницы — то, что в ссылке у близкого. У ссылки с ключом —
    /// копия `EtaShare.address(forKey: key)` для сборки до 14.12 (откат
    /// TestFlight): без поля она не прочитала бы ссылку вовсе и потеряла бы
    /// имя и настройки; писать по адресу она не сможет, а смена даст новую.
    var token: String
    /// Ключ записи (14.12); nil — ссылка, созданная до него: её адрес и есть
    /// ключ. Такая живёт до своей смены (30 дней) и тогда получает ключ —
    /// смена сейчас погасила бы ссылку, которая уже у близкого.
    var key: String?
    var createdAt: Date
    /// Кому — как назвал водитель («Мама»). Только на телефоне.
    var name: String
    /// Выключатель в настройках: ссылка есть, но не живёт.
    var enabled = true
    /// Ссылку сменили (30 дней), а новую ещё не отправили.
    var needsResend = false

    static func make(name: String, now: Date) -> FamilyLink {
        let key = EtaShare.makeToken()
        return FamilyLink(token: EtaShare.address(forKey: key), key: key, createdAt: now, name: name)
    }

    /// Чем писать: ключом, если он есть, иначе — старым токеном.
    var write: EtaShare.WriteKey {
        key.map { .secret($0) } ?? .legacy(token)
    }

    /// Пора сменить токен: прошло 30 дней.
    func needsRotation(now: Date) -> Bool {
        now.timeIntervalSince(createdAt) >= AppConfig.familyLinkRotationDays * 86_400
    }

    /// Новый ключ и адрес — старая ссылка у близкого гаснет («сейчас не в
    /// пути» навсегда), новую надо переслать. Старая ссылка без ключа здесь
    /// и получает ключ.
    func rotated(now: Date) -> FamilyLink {
        var copy = self
        let key = EtaShare.makeToken()
        copy.key = key
        copy.token = EtaShare.address(forKey: key)
        copy.createdAt = now
        copy.needsResend = true
        return copy
    }

    /// Страница близкого: постоянная (`/api/eta/f/…`). Адрес — от ключа, а не
    /// из копии: ссылка и запись не разойдутся.
    func url(base: URL) -> URL {
        base.appendingPathComponent("api").appendingPathComponent("eta")
            .appendingPathComponent("f").appendingPathComponent(write.address)
    }
}

nonisolated enum FamilyShare {
    /// Что сейчас видит близкий.
    enum Phase: Equatable, Sendable {
        case idle
        case driving(arrival: Date)
    }

    /// Живая ссылка — только в поездке домой, по направлению призрака:
    /// ссылка есть и включена, водитель не поставил паузу на эту поездку.
    static func phase(link: FamilyLink?, pausedThisTrip: Bool, isTripActive: Bool,
                      ghost: (toHome: Bool, arrival: Date)?) -> Phase {
        guard let link, link.enabled, !pausedThisTrip, isTripActive,
              let ghost, ghost.toHome else { return .idle }
        return .driving(arrival: ghost.arrival)
    }

    /// Чем закрыть живую ссылку: дома — «дома в 18:42», иначе (пауза,
    /// поездка свернула не домой) — «сейчас не в пути».
    static func endStatus(nearHome: Bool) -> EtaShare.Status {
        nearHome ? .arrived : .ended
    }
}
