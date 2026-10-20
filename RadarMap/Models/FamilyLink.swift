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
//    * на сервере — только токен и, пока едем, четыре поля «Поделиться
//      прибытием», в памяти. Никакой позиции: время прибытия и «в пути /
//      дома». Токен меняется каждые 30 дней — долгоживущий идентификатор
//      человека не копится; новую ссылку водитель пересылает сам;
//    * пауза в один тап — на эту поездку; выключатель — в настройках.
//

import Foundation

nonisolated struct FamilyLink: Codable, Equatable, Sendable {
    var token: String
    var createdAt: Date
    /// Кому — как назвал водитель («Мама»). Только на телефоне.
    var name: String
    /// Выключатель в настройках: ссылка есть, но не живёт.
    var enabled = true
    /// Ссылку сменили (30 дней), а новую ещё не отправили.
    var needsResend = false

    static func make(name: String, now: Date) -> FamilyLink {
        FamilyLink(token: EtaShare.makeToken(), createdAt: now, name: name)
    }

    /// Пора сменить токен: прошло 30 дней.
    func needsRotation(now: Date) -> Bool {
        now.timeIntervalSince(createdAt) >= AppConfig.familyLinkRotationDays * 86_400
    }

    /// Новый токен — старая ссылка у близкого гаснет («сейчас не в пути»
    /// навсегда), новую надо переслать.
    func rotated(now: Date) -> FamilyLink {
        var copy = self
        copy.token = EtaShare.makeToken()
        copy.createdAt = now
        copy.needsResend = true
        return copy
    }

    /// Страница близкого: постоянная (`/api/eta/f/…`).
    func url(base: URL) -> URL {
        base.appendingPathComponent("api").appendingPathComponent("eta")
            .appendingPathComponent("f").appendingPathComponent(token)
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
