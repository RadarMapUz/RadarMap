//
//  FamilyLink.swift
//  RadarMap
//
//  «Близкие видят прибытие» (12б.6, 22.1): до пяти человек, у каждого своя
//  постоянная ссылка и свой режим. «Мама» видит «в пути — будет в 18:40»,
//  когда водитель едет домой, и «сейчас не в пути» всё остальное время.
//
//  Модель — здесь; когда и что отправлять — FamilyShare (чистый, с тестами).
//
//    * у каждого близкого свой ключ записи W и свой адрес R = хэш W (14.12):
//      убрать одного или сменить ему ссылку — остальные ссылки живут;
//    * принудительной смены раз в 30 дней больше нет (решение 21.10): сервер
//      и так держит только время прибытия в памяти, пока идёт поездка, а
//      писать может только телефон. «Сменить ссылку» — по человеку, когда
//      понадобится;
//    * ссылка до 22.1 (одна, `FamilyLink`) читается и становится первым
//      близким с тем же адресом и ключом — ссылка, которая уже у мамы,
//      продолжает работать.
//

import Foundation

/// Один близкий: имя, смайлик, режим и своя ссылка.
nonisolated struct FamilyRecipient: Codable, Equatable, Identifiable, Sendable {
    /// Когда близкий видит поездку.
    enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
        /// «Когда еду домой» — по умолчанию: цель маршрута — Дом, дорога
        /// узнана как «домой» или водитель нажал «Еду домой».
        case home
        /// «Каждая поездка» — для родителей начинающего водителя; на экране
        /// выбора — явное предупреждение.
        case everyTrip

        var id: String { rawValue }
    }

    let id: UUID
    /// Как назвал водитель («Мама»). Только на телефоне — на сервер не уходит.
    var name: String
    /// «👩‍🦳» — необязательно; только на телефоне.
    var emoji: String
    var mode: Mode
    /// Адрес страницы — то, что в ссылке у близкого. У ссылки с ключом —
    /// копия `EtaShare.address(forKey: key)`; у ссылки до 14.12 — сам токен.
    var token: String
    /// Ключ записи (14.12); nil — ссылка до него: её адрес и есть ключ.
    var key: String?
    var createdAt: Date
    /// Выключатель: близкий есть, но поездок не видит.
    var enabled: Bool
    /// Когда ссылку отправили (лист «Поделиться» ответил «ушло»); nil — ещё
    /// нет. Кому ссылку не отправили, тому и поездку не шлём: «Видят: Мама»
    /// была бы неправдой.
    var linkSentAt: Date?

    init(name: String, emoji: String = "", mode: Mode = .home, now: Date, id: UUID = UUID()) {
        let key = EtaShare.makeToken()
        self.id = id
        self.name = name
        self.emoji = emoji
        self.mode = mode
        self.token = EtaShare.address(forKey: key)
        self.key = key
        self.createdAt = now
        self.enabled = true
        self.linkSentAt = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, emoji, mode, token, key, createdAt, enabled, linkSentAt
    }

    /// Новые поля — с умолчаниями (ARCHITECTURE, правило 18): запись на диске
    /// старше поля не должна терять всех близких разом.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji) ?? ""
        // Режим, которого эта сборка не знает (запись новой сборки после
        // отката), — «когда еду домой»: самый сдержанный, а не потеря близкого.
        mode = (try? c.decodeIfPresent(Mode.self, forKey: .mode)) ?? .home
        token = try c.decode(String.self, forKey: .token)
        key = try c.decodeIfPresent(String.self, forKey: .key)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        linkSentAt = try c.decodeIfPresent(Date.self, forKey: .linkSentAt)
    }

    /// Чем писать: ключом, если он есть, иначе — старым токеном.
    var write: EtaShare.WriteKey {
        key.map { .secret($0) } ?? .legacy(token)
    }

    /// Страница близкого: постоянная (`/api/eta/f/…`). Адрес — от ключа, а не
    /// из копии: ссылка и запись не разойдутся.
    func url(base: URL) -> URL {
        base.appendingPathComponent("api").appendingPathComponent("eta")
            .appendingPathComponent("f").appendingPathComponent(write.address)
    }

    /// Подписка в Telegram (22.3): `t.me/<бот>?start=f_<адрес>`. Имя бота
    /// телефон узнаёт у сервера (X-Eta-Bot); неправильное — ссылки нет. Ссылка
    /// без ключа (до 14.12) не подписывается: по ней любой читатель мог бы
    /// прислать ложное «дома» (family_notify.deep_link).
    func telegramURL(bot: String?) -> URL? {
        guard key != nil, let bot = FamilyShare.validBot(bot) else { return nil }
        return URL(string: "https://t.me/\(bot)?start=f_\(write.address)")
    }

    /// «Сменить ссылку»: новый ключ и адрес. Старая ссылка у близкого гаснет
    /// («сейчас не в пути» навсегда), новую надо отправить; ссылка до 14.12
    /// здесь и получает ключ.
    func withNewLink(now: Date) -> FamilyRecipient {
        var copy = self
        let key = EtaShare.makeToken()
        copy.key = key
        copy.token = EtaShare.address(forKey: key)
        copy.createdAt = now
        copy.linkSentAt = nil
        return copy
    }

    /// Ссылка у близкого есть — поездки ему слать есть смысл.
    var isReachable: Bool { enabled && linkSentAt != nil }

    /// «Мама 👩‍🦳» — для списков и капсулы.
    var title: String { emoji.isEmpty ? name : "\(name) \(emoji)" }
}

/// Все близкие водителя и общие настройки.
nonisolated struct FamilyCircle: Codable, Equatable, Sendable {
    var recipients: [FamilyRecipient] = []
    /// «Как вас назовут близким» — уходит на сервер с поездкой (≤ 32 знаков,
    /// только в памяти записи); пусто — «Водитель» на стороне сервера.
    var driverName: String = ""
    /// «Пауза до завтра» для всех: до этого момента поездок не видит никто.
    var pausedUntil: Date?

    init(recipients: [FamilyRecipient] = [], driverName: String = "", pausedUntil: Date? = nil) {
        self.recipients = recipients
        self.driverName = driverName
        self.pausedUntil = pausedUntil
    }

    private enum CodingKeys: String, CodingKey { case recipients, driverName, pausedUntil }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recipients = try c.decodeIfPresent([FamilyRecipient].self, forKey: .recipients) ?? []
        driverName = try c.decodeIfPresent(String.self, forKey: .driverName) ?? ""
        pausedUntil = try c.decodeIfPresent(Date.self, forKey: .pausedUntil)
    }

    var canAdd: Bool { recipients.count < AppConfig.familyMaxRecipients }

    func isPaused(now: Date) -> Bool {
        pausedUntil.map { now < $0 } ?? false
    }

    /// Имя для сервера: обрезанное, не длиннее 32 знаков; пустое — nil.
    var sentName: String? {
        let trimmed = driverName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(AppConfig.familyDriverNameMax))
    }

    /// «Пауза до завтра» — до начала следующего дня.
    static func pauseEnd(now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(86_400)
    }

    /// Ссылка до 22.1 — первым близким, с тем же адресом и ключом: у мамы
    /// ссылка не меняется. Режим — «когда еду домой» (так она и работала);
    /// отправленной считается, если её не просили переслать после смены.
    static func migrated(from legacy: FamilyLink) -> FamilyCircle {
        let recipient = FamilyRecipient(migrating: legacy)
        return FamilyCircle(recipients: [recipient])
    }
}

extension FamilyRecipient {
    nonisolated init(migrating legacy: FamilyLink) {
        id = UUID()
        name = legacy.name
        emoji = ""
        mode = .home
        token = legacy.token
        key = legacy.key
        createdAt = legacy.createdAt
        enabled = legacy.enabled ?? true
        linkSentAt = legacy.needsResend == true ? nil : legacy.createdAt
    }
}

/// Семейная ссылка до 22.1 — одна на одного близкого. Только читается: из
/// неё миграция в `FamilyCircle` (Storage.familyLink → familyCircle).
nonisolated struct FamilyLink: Codable, Equatable, Sendable {
    var token: String
    var key: String?
    var createdAt: Date
    var name: String
    var enabled: Bool?
    var needsResend: Bool?
}
