//
//  FamilyShareService.swift
//  RadarMap
//
//  «Близкие видят прибытие» (12б.6, 22.1): до пяти близких, у каждого своя
//  ссылка и режим. Правила — в FamilyShare, поездка — автомат FamilyTrip;
//  здесь хранение, отправка и таймеры. Шлёт тем же путём, что «Поделиться
//  прибытием» (EtaShare): ключ записи, адрес, время, статус, плюс «домой» и
//  имя водителя — ни точки, ни цели, ни устройства, ни имени близкого.
//

import Foundation
import os

@MainActor
@Observable
final class FamilyShareService {
    nonisolated deinit {}

    private(set) var circle: FamilyCircle {
        didSet { if !Self.isDemo { save() } }
    }
    /// Ключи записи — в связке (FamilyKeys); что в ней точно лежит.
    @ObservationIgnored private var knownKeys: [UUID: String]
    @ObservationIgnored private let keyStore: any SecretStore
    /// Кому поездка видна прямо сейчас: «в пути» доставлено и не закрыто.
    private(set) var liveIDs: Set<UUID> = []
    /// Пауза на эту поездку (один тап); снимается стартом следующей —
    /// не склеенной с этой.
    private(set) var pausedThisTrip = false
    /// Поездка сейчас — домой (по любому из признаков): пункта «Еду домой»
    /// тогда нет.
    private(set) var isHeadingHome = false
    /// Тихая строка «Мама увидит, что вы едете домой» — раз в день.
    private(set) var notice: String?

    /// Пульт гасит общие ссылки («Поделиться прибытием») — и семейные.
    @ObservationIgnored var allowedByConfig: () -> Bool = { true }
    /// Что известно о поездке — собирает AppEnvironment (familyContext).
    @ObservationIgnored var context: () -> FamilyShare.Context? = { nil }
    /// Имя Telegram-бота, если сервер его назвал (X-Eta-Bot).
    @ObservationIgnored var telegramBot: () -> String? = { nil }
    @ObservationIgnored private let api = APIClient()
    /// Автомат поездки. Не наблюдается: меняется на каждом фиксе, а наружу
    /// выходят только три флага выше — и только при смене (publish).
    @ObservationIgnored private var trip = FamilyTrip()
    /// Последняя отправка в очереди: все запросы уходят по одному и по
    /// порядку — «дома»/«не в пути» не обгонит «в пути», ушедшее раньше.
    @ObservationIgnored private var chain: Task<Bool, Never>?
    /// Растёт на каждом закрытии ссылки близкого: ответ «в пути», вернувшийся
    /// после него, не поднимает её снова (ARCHITECTURE, правило 12).
    @ObservationIgnored private var generation: [UUID: Int] = [:]
    /// Ожидание склейки (магазин по пути) — таймер на случай, если до конца
    /// срока не придёт ни поездки, ни update.
    @ObservationIgnored private var holdTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init(keyStore: any SecretStore = KeychainSecretStore(service: AppConfig.familyKeychainService)) {
        self.keyStore = keyStore
        let loaded = Self.load(keyStore: keyStore, now: Date())
        circle = loaded.circle
        knownKeys = loaded.known
    }

    /// Имена тех, кто видит сейчас, — для капсулы «Видят: Мама, Дилноза».
    var liveNames: [String] {
        circle.recipients.filter { liveIDs.contains($0.id) }.map(\.name)
    }

    func recipient(_ id: UUID) -> FamilyRecipient? {
        circle.recipients.first { $0.id == id }
    }

    // MARK: - Настройки

    /// Новый близкий; nil — уже пятеро.
    @discardableResult
    func add(name: String, emoji: String = "", mode: FamilyRecipient.Mode = .home,
             now: Date = Date()) -> UUID? {
        guard circle.canAdd else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipient = FamilyRecipient(name: trimmed.isEmpty ? String(localized: "Близкий") : trimmed,
                                        emoji: emoji, mode: mode, now: now)
        circle.recipients.append(recipient)
        return recipient.id
    }

    func rename(_ id: UUID, to name: String) {
        edit(id) { $0.name = name }
    }

    func setEmoji(_ id: UUID, _ emoji: String) {
        edit(id) { $0.emoji = emoji }
    }

    func setMode(_ id: UUID, _ mode: FamilyRecipient.Mode) {
        edit(id) { $0.mode = mode }
        update()
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        edit(id) { $0.enabled = enabled }
        update()
    }

    /// Ссылку отправили (лист «Поделиться» сообщил, что ушло): с этого
    /// момента близкому есть смысл слать поездки — и в идущей тоже.
    func markSent(_ id: UUID, now: Date = Date()) {
        edit(id) {
            $0.linkSentAt = now
            $0.linkLost = nil
        }
        update()
    }

    /// «Сменить ссылку»: у близкого — «сейчас не в пути» навсегда, подписка
    /// в Telegram снята, новую ссылку надо отправить. Ключ снят до смены.
    func changeLink(_ id: UUID, now: Date = Date()) {
        guard let old = recipient(id) else { return }
        revoke(old, now: now)
        edit(id) { $0 = $0.withNewLink(now: now) }
        Log.network.notice("близкие: ссылка сменена по просьбе водителя")
    }

    /// Убрать близкого: его ссылка гаснет («сейчас не в пути»), подписка в
    /// Telegram снята, остальные живут. Ключ снят до удаления (ревью 14.1).
    func remove(_ id: UUID, now: Date = Date()) {
        guard let old = recipient(id) else { return }
        revoke(old, now: now)
        circle.recipients.removeAll { $0.id == id }
    }

    func setDriverName(_ name: String) {
        circle.driverName = String(name.prefix(AppConfig.familyDriverNameMax))
    }

    /// Близкие из iCloud (27.F). Ключи записи в iCloud не уходят, поэтому
    /// знакомый близкий получает только имя, смайлик, режим и выключатель —
    /// его ссылка на этом телефоне остаётся своей. Новый (восстановление на
    /// другом телефоне) заводится со СВОЕЙ новой ссылкой, ещё не отправленной:
    /// «Видят: Мама» не появится, пока ссылку не отправят заново. Удалённый на
    /// другом телефоне — удаляется и здесь, с погашенной ссылкой.
    func applyCloud(contacts: [CloudPayload.FamilyContact], removed: Set<UUID>, driverName: String?,
                    now: Date = Date()) {
        for contact in contacts where !removed.contains(contact.id) {
            if recipient(contact.id) != nil {
                edit(contact.id) {
                    $0.name = contact.name
                    $0.emoji = contact.emoji
                    $0.mode = contact.mode
                    $0.enabled = contact.enabled
                }
            } else if circle.canAdd {
                var fresh = FamilyRecipient(name: contact.name, emoji: contact.emoji, mode: contact.mode,
                                            now: now, id: contact.id)
                fresh.enabled = contact.enabled
                circle.recipients.append(fresh)
            }
        }
        for id in removed { remove(id, now: now) }
        if let driverName, driverName != circle.driverName { setDriverName(driverName) }
        update(now: now)
    }

    /// «Пауза до завтра» — для всех; идущая поездка гаснет сразу.
    func pauseUntilTomorrow(now: Date = Date()) {
        circle.pausedUntil = FamilyCircle.pauseEnd(now: now)
        perform(trip.closeAll(.ended))
    }

    func resumeSharing() {
        circle.pausedUntil = nil
        update()
    }

    private func edit(_ id: UUID, _ change: (inout FamilyRecipient) -> Void) {
        guard let index = circle.recipients.firstIndex(where: { $0.id == id }) else { return }
        change(&circle.recipients[index])
    }

    // MARK: - Поездка

    func tripStarted() {
        trip.tripStarted()
    }

    /// Пауза в один тап — на эту поездку, для всех.
    func pause() {
        perform(trip.pause())
    }

    /// «Еду домой» — одно касание в поездке.
    func goingHome() {
        trip.goingHome()
        update()
    }

    /// Фикс в поездке (и любое изменение, которое может поменять, кому
    /// видно): кому слать, что слать, кого закрыть — решает FamilyTrip.
    func update(now: Date = Date()) {
        // Близких нет и слать некому — на фиксе ничего не считаем (правило 8).
        guard !circle.recipients.isEmpty || !trip.open.isEmpty,
              allowedByConfig(), let context = context() else { return }
        perform(trip.update(circle, context: context, now: now))
        if trip.holdUntil == nil { cancelHoldTimer() }
    }

    /// Конец поездки: дома — «дома в 18:47», «Стоп» рукой и пассажир — «не в
    /// пути», автостоп в другом месте — ждём склейки (FamilyShare.endAction).
    func tripEnded(_ end: NavigationFlow.TripEnd, arrivedHome: Bool, now: Date = Date()) {
        perform(trip.tripEnded(end, arrivedHome: arrivedHome, now: now))
        cancelHoldTimer()
        guard trip.holdUntil != nil else { return }
        holdTask = Task { [weak self] in
            await Task.pause(seconds: AppConfig.familyHoldSeconds)
            guard !Task.isCancelled, let self, self.context()?.isTripActive != true else { return }
            self.perform(self.trip.finishHold())
        }
    }

    private func cancelHoldTimer() {
        holdTask?.cancel()
        holdTask = nil
    }

    // MARK: - Отправка

    /// Исполнить решения автомата и вывести наружу то, что видно.
    private func perform(_ actions: [FamilyTrip.Action]) {
        for action in actions {
            switch action {
            case let .drive(id, arrival, home):
                guard let recipient = recipient(id) else { trip.failed(id, now: Date()); continue }
                sendDriving(recipient, arrival: arrival, home: home)
            case let .close(id, status, home):
                guard let recipient = recipient(id).flatMap({ writable($0) }) else { continue }
                generation[id, default: 0] &+= 1
                enqueue(FamilyShare.payload(write: recipient.write, status: status, arrival: nil, home: home,
                                            name: circle.sentName, now: Date()))
            }
        }
        publish()
    }

    /// Наблюдаемые флаги — только при смене: их читают капсула и меню.
    private func publish() {
        if liveIDs != trip.live { liveIDs = trip.live }
        if pausedThisTrip != trip.pausedThisTrip { pausedThisTrip = trip.pausedThisTrip }
        if isHeadingHome != trip.headingHome { isHeadingHome = trip.headingHome }
    }

    /// Ключ из связки, если при запуске она его не отдала (FamilyKeys). Связка
    /// всё ещё недоступна — nil: писать адресом вместо ключа нельзя. Записи в
    /// ней нет — ключ потерян навсегда: новая ссылка и просьба отправить её
    /// заново (FamilyKeys.restored), близкий выпадает из отправки.
    private func writable(_ recipient: FamilyRecipient) -> FamilyRecipient? {
        guard recipient.isKeyLocked else { return recipient }
        do {
            guard let key = try keyStore.read(account: recipient.id.uuidString) else {
                Log.app.error("близкие: ключа нет в связке — новая ссылка, водителя просим отправить заново")
                _ = trip.forget(recipient.id)
                generation[recipient.id, default: 0] &+= 1
                edit(recipient.id) { $0 = $0.relinkedAfterLoss(now: Date()) }
                publish()
                return nil
            }
            knownKeys[recipient.id] = key
            // Ключ — только в память: файл и так помнит, что он в связке.
            circle.recipients = circle.recipients.map { $0.id == recipient.id ? Self.withKey(key, $0) : $0 }
            return Self.withKey(key, recipient)
        } catch {
            Log.app.error("близкие: связка ключей всё ещё недоступна (\(String(describing: error), privacy: .public))")
            return nil
        }
    }

    private static func withKey(_ key: String, _ recipient: FamilyRecipient) -> FamilyRecipient {
        var copy = recipient
        copy.key = key
        return copy
    }

    private func sendDriving(_ recipient: FamilyRecipient, arrival: Date?, home: Bool) {
        guard let recipient = writable(recipient) else {
            trip.failed(recipient.id, now: Date())
            return
        }
        let id = recipient.id
        let started = generation[id, default: 0]
        let request = enqueue(FamilyShare.payload(write: recipient.write, status: .driving, arrival: arrival,
                                                  home: home, name: circle.sentName, now: Date()))
        Task {
            let delivered = await request.value
            // Пока ответ шёл, ссылку закрыли (приехали, пауза, убрали
            // близкого): «в пути» уже не правда, и она не воскресает.
            guard generation[id, default: 0] == started else { return }
            if delivered {
                trip.delivered(id, arrival: arrival, home: home, at: Date())
            } else {
                trip.failed(id, now: Date())
            }
            publish()
            if delivered { considerNotice() }
        }
    }

    /// Последнее «не в пути» по ссылке, которую убирают или меняют, — с
    /// revoke: сервер сразу снимает её подписки в Telegram. Шлётся и вне
    /// поездки: подписка живёт месяцами. Ссылку, которую так и не отправили,
    /// никто не видел — слать нечего.
    private func revoke(_ recipient: FamilyRecipient, now: Date) {
        let id = recipient.id
        guard recipient.linkSentAt != nil || trip.open.contains(id) else { return }
        // Ключ так и не отдан — закрыть ссылку нечем; она погаснет сама
        // («сейчас не в пути» по сроку на сервере).
        guard let recipient = writable(recipient) else { return }
        let home = trip.forget(id)
        generation[id, default: 0] &+= 1
        enqueue(FamilyShare.payload(write: recipient.write, status: .ended, arrival: nil, home: home,
                                    name: circle.sentName, now: now, revoke: true))
        publish()
    }

    /// В очередь: после всего, что ушло раньше.
    @discardableResult
    private func enqueue(_ body: [String: Any]) -> Task<Bool, Never> {
        // Демо-близкие для снимков никуда не пишут: их ключи выдуманы.
        if Self.isDemo { return Task { false } }
        let previous = chain
        // [String: Any] не Sendable — тело уходит в задачу готовыми байтами.
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: body)
        } catch {
            Log.network.error("близкие: тело не собралось — \(error.localizedDescription, privacy: .public)")
            return Task { false }
        }
        let task = Task {
            _ = await previous?.value
            guard allowedByConfig() else { return false }
            return await api.postAccepted("api/eta", body: data)
        }
        chain = task
        return task
    }

    // MARK: - Строка «Мама увидит…»

    private func considerNotice(now: Date = Date()) {
        guard notice == nil, let context = context() else { return }
        let names = liveNames
        guard FamilyShare.showsNotice(headingHome: isHeadingHome, liveCount: names.count,
                                      screenVisible: context.screenVisible,
                                      lastShown: Storage.date(.familyNoticeShownAt), now: now)
        else { return }
        Storage.set(now, for: .familyNoticeShownAt)
        notice = FamilyShare.noticeText(names: names)
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            await Task.pause(seconds: AppConfig.familyNoticeSeconds)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: - Хранение

    /// Скриншот-хук `-demoFamily` (DEBUG): трое близких в памяти, на диск не
    /// пишется ничего.
    private static var isDemo: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-demoFamily")
        #else
        false
        #endif
    }

    #if DEBUG
    private static func demoCircle() -> FamilyCircle {
        let now = Date()
        // На узбекском интерфейсе — узбекские имена латиницей (снимки App Store).
        let uzbek = (Bundle.main.preferredLocalizations.first ?? "ru").hasPrefix("uz")
        var mother = FamilyRecipient(name: uzbek ? "Oyim" : "Мама", emoji: "👩‍🦳", now: now)
        mother.linkSentAt = now.addingTimeInterval(-9 * 86_400)
        var wife = FamilyRecipient(name: uzbek ? "Dilnoza" : "Дилноза", emoji: "👩", now: now)
        wife.linkSentAt = now.addingTimeInterval(-2 * 86_400)
        let father = FamilyRecipient(name: uzbek ? "Dadam" : "Папа", emoji: "👴", mode: .everyTrip, now: now)
        return FamilyCircle(recipients: [mother, wife, father], driverName: uzbek ? "Aziz" : "Азиз")
    }

    /// Демо: первая — «видит сейчас».
    func showDemoLive() {
        guard Self.isDemo, let first = circle.recipients.first else { return }
        liveIDs = [first.id]
    }
    #endif

    private func save() {
        let disk = FamilyKeys.persisted(circle, in: keyStore, known: &knownKeys)
        Self.write(disk)
    }

    private static func write(_ disk: FamilyCircle) {
        do {
            Storage.set(try JSONEncoder().encode(disk), for: .familyCircle)
        } catch {
            Log.app.error("близкие не записались: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Круг близких; нет — ссылка до 22.1 становится первым близким (тот же
    /// адрес и ключ — у мамы ссылка не меняется), старый ключ стирается.
    /// Ключи записи — в связку (FamilyKeys); файл переписывается без них
    /// только после того, как связка их приняла.
    private static func load(keyStore: any SecretStore, now: Date) -> FamilyKeys.Loaded {
        #if DEBUG
        if isDemo { return FamilyKeys.Loaded(circle: demoCircle(), known: [:], needsResave: false) }
        #endif
        if let data = Storage.data(.familyCircle) {
            do {
                let disk = try JSONDecoder().decode(FamilyCircle.self, from: data)
                var loaded = FamilyKeys.restored(disk, from: keyStore, now: now)
                if loaded.needsResave {
                    write(FamilyKeys.persisted(loaded.circle, in: keyStore, known: &loaded.known))
                    Log.app.notice("близкие: ключи ссылок перенесены в связку ключей или выданы заново")
                }
                return loaded
            } catch {
                Log.app.error("близкие не прочитались: \(error.localizedDescription, privacy: .public)")
                return FamilyKeys.Loaded(circle: FamilyCircle(), known: [:], needsResave: false)
            }
        }
        guard let data = Storage.data(.familyLink) else {
            return FamilyKeys.Loaded(circle: FamilyCircle(), known: [:], needsResave: false)
        }
        do {
            let legacy = try JSONDecoder().decode(FamilyLink.self, from: data)
            let circle = FamilyCircle.migrated(from: legacy)
            var known: [UUID: String] = [:]
            write(FamilyKeys.persisted(circle, in: keyStore, known: &known))
            Storage.remove(.familyLink)
            Log.app.notice("семейная ссылка перенесена в список близких (22.1)")
            return FamilyKeys.Loaded(circle: circle, known: known, needsResave: false)
        } catch {
            Log.app.error("семейная ссылка не прочиталась: \(error.localizedDescription, privacy: .public)")
            return FamilyKeys.Loaded(circle: FamilyCircle(), known: [:], needsResave: false)
        }
    }
}
