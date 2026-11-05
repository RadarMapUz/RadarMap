//
//  MemoryPressure.swift
//  RadarMap
//
//  Ответ на «система просит освободить память».
//
//  Чего не было. `grep didReceiveMemoryWarning` по всему проекту не находил
//  ничего: iOS честно присылает предупреждение ПЕРЕД тем, как убить
//  приложение, а приложение на него не отвечало ничем. Между тем телеметрия
//  показала 73 отстрела по памяти за сорок суток (`crash_carplay_memory.md`)
//  — то есть семьдесят три раза система предупредила и семьдесят три раза не
//  получила в ответ ни байта.
//
//  Для водителя это выглядит как падение: экран машины возвращается на
//  рабочий стол посреди поездки.
//
//  Что здесь есть и чего НЕТ.
//
//  Освобождается только то, что можно построить заново из данных, которые
//  никуда не делись: кэш сетевых ответов, выборка камер видимой области,
//  разобранные слои стиля. Ничего, что нельзя восстановить, и ничего, от чего
//  зависит ПРЕДУПРЕЖДЕНИЕ О КАМЕРЕ: база камер, окно слежения, подписанный
//  индекс тайлов и история поездок не трогаются никогда. Приложение под
//  давлением памяти обязано стать беднее картинкой, а не глупее.
//
//  Подписчики регистрируются сами и снимаются вместе со своим объектом —
//  списка «кого чистить» в одном месте нет намеренно: он бы устарел первым.
//
//  С 36A чистка — не только по предупреждению системы. Ещё два повода:
//  телефонная сцена ушла в фон, а процесс работает (поездка, экран машины) —
//  карта телефона не видна, её кэш тайлов в памяти — чистый вес; и потолок
//  следа в поездке
//  (`AppConfig.engineMemoryCeilingBytes`, сверяет карта на своём такте).
//  Предупреждение ждать поздно: на SE в фоне рядом с CarPlay система чаще
//  выгружает молча, чем предупреждает, а выгрузка — это поездка без
//  оповещений. Повод передаётся подписчику: видимая карта машины на уход
//  телефона в фон ничего не отдаёт.
//

import os
import Darwin
import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
enum MemoryPressure {

    /// Почему чистим.
    enum Reason: Equatable, Sendable {
        /// Система предупредила (didReceiveMemoryWarning).
        case warning
        /// Телефонная сцена ушла в фон, а процесс работает дальше (поездка,
        /// CarPlay; 36A): карта на телефоне не видна, а процесс живёт часами —
        /// и на SE рядом с CarPlay первым кандидатом на выгрузку (jetsam)
        /// становится самый толстый. Выгрузка = нет оповещений.
        case background
        /// Поездка, след процесса выше потолка (AppConfig.engineMemoryCeilingBytes);
        /// `footprint` — сколько он сейчас, байты (жёсткий верх машины, 40I).
        case ceiling(footprint: UInt64)

        /// Память на самом деле тесная, а не «экран не виден»: только тогда
        /// отдаём то, что нужно видимому экрану машины (книги поиска).
        var isTight: Bool { self != .background }
    }

    /// Сколько раз система просила освободить память за сеанс. Идёт в
    /// суточный отчёт: без этого числа «приложение вылетает» остаётся
    /// ощущением, а не событием, у которого есть частота.
    private(set) static var warnings = 0

    /// Кого будить. Слабые ссылки: подписчик уходит вместе со своим экраном,
    /// отписываться вручную не нужно.
    private static var subscribers: [(Reason) -> Bool] = []

    /// Зарегистрировать уборку на ТЕСНУЮ память (предупреждение, потолок).
    /// Замыкание возвращает false, когда его хозяин уже мёртв, — тогда
    /// запись выбрасывается.
    static func onWarning<Owner: AnyObject>(_ owner: Owner,
                                            _ clean: @escaping (Owner) -> Void) {
        onTrim(owner) { owner, reason in
            if reason.isTight { clean(owner) }
        }
    }

    /// Зарегистрировать уборку на любую причину — хозяин сам решает, что
    /// отдать (карта в фоне отдаёт тайлы, карта на экране машины — нет).
    static func onTrim<Owner: AnyObject>(_ owner: Owner,
                                         _ clean: @escaping (Owner, Reason) -> Void) {
        start()
        subscribers.append { [weak owner] reason in
            guard let owner else { return false }
            clean(owner, reason)
            return true
        }
    }

    /// Кэш на весь процесс без хозяина (статический): живёт вечно.
    static func onTrim(_ clean: @escaping (Reason) -> Void) {
        start()
        subscribers.append { reason in
            clean(reason)
            return true
        }
    }

    #if canImport(UIKit)
    private static var started = false

    private static func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { relieve() }
            }
    }
    #else
    private static func start() {}
    #endif

    /// Системное предупреждение: освободить всё, что можно построить заново.
    static func relieve() {
        warnings += 1
        trim(.warning)
    }

    /// Телефонная сцена ушла в фон. Чистим, только если процесс продолжает
    /// работать (поездка, экран машины): иначе он засыпает, и возврат к
    /// карте не должен перечитывать тайлы.
    static func phoneSceneLeft(keepsWorking: Bool) {
        guard keepsWorking else { return }
        trim(.background)
    }

    static func trim(_ reason: Reason) {
        // Кэш сетевых ответов: любая его строка берётся из сети повторно, и
        // ни одна не нужна для предупреждения о камере. Чистка — SQLite-проход
        // CFNetwork, поэтому не на главном (аудит 05.11, №6): переход в фон
        // идёт внутри того же бюджета сторожа, что завис в 2.2.43.
        Task.detached(priority: .utility) { URLCache.shared.removeAllCachedResponses() }
        subscribers = subscribers.filter { $0(reason) }
        Log.app.notice("память: чистка (\(String(describing: reason), privacy: .public)), предупреждений за сеанс \(warnings, privacy: .public)")
    }

    // MARK: - Потолок в поездке

    private static var lastCeilingTrim: TimeInterval?

    /// Машина подключена (ставит AppEnvironment): потолок — выше (40I).
    static var isCarPlayConnected = false

    /// Потолок следа: с машиной — замеренный рабочий набор её карты (40I).
    nonisolated static func ceiling(carConnected: Bool) -> UInt64 {
        carConnected ? AppConfig.engineMemoryCeilingCarPlayBytes : AppConfig.engineMemoryCeilingBytes
    }

    /// Что карта отдаёт на чистку.
    enum Release: Equatable, Sendable {
        /// Ничего: её рабочий набор нужен на экране.
        case nothing
        /// Выборку камер и разобранные слои темы — движок отвечает сам
        /// (системное предупреждение он слышит без нас).
        case selection
        /// И то, и кэш тайлов движка в памяти.
        case selectionAndEngine
    }

    /// Решение для одной карты. Видимая карта машины не отдаёт ничего ни на
    /// уход телефона в фон, ни на потолок (40I): потолок — про процесс, а её
    /// кэш тайлов и выборка камер — то, что водитель видит сейчас; чистка
    /// каждые 2 мин перекладывала камеры и поднимала тайлы с диска на ходу.
    /// Но не выше жёсткого верха (`engineMemoryHardCeilingCarPlayBytes`):
    /// след — на процесс, а видимых карт в машине до трёх (экран, плитка,
    /// приборка); перечитать тайлы с диска дешевле, чем потерять процесс, —
    /// выгрузка = поездка без оповещений. Скрытая карта (телефон в кармане)
    /// отдаёт всё, как раньше.
    nonisolated static func release(_ reason: Reason, hidden: Bool, inCar: Bool) -> Release {
        switch reason {
        case .background:
            return hidden ? .selectionAndEngine : .nothing
        case .ceiling(let footprint):
            let keeps = !hidden && inCar && footprint <= AppConfig.engineMemoryHardCeilingCarPlayBytes
            return keeps ? .nothing : .selectionAndEngine
        case .warning:
            return .selection
        }
    }

    /// Проверить след процесса и почистить, если он выше потолка. Зовёт
    /// карта на своём редком такте (не чаще AppConfig.engineMemoryCheckSeconds),
    /// своего таймера здесь нет — лишних пробуждений тоже.
    static func checkCeiling(now: TimeInterval) {
        guard let footprint = footprintBytes(),
              shouldTrim(footprint: footprint, ceiling: ceiling(carConnected: isCarPlayConnected),
                         lastTrim: lastCeilingTrim, now: now) else { return }
        lastCeilingTrim = now
        Log.app.notice("память: след \(footprint / 1_048_576, privacy: .public) МБ выше потолка")
        trim(.ceiling(footprint: footprint))
    }

    /// Пора ли чистить по потолку: выше него и не чаще раза в
    /// `engineMemoryTrimIntervalSeconds` — иначе на рабочем наборе выше
    /// потолка движок перечитывал бы тайлы с диска каждые полминуты.
    nonisolated static func shouldTrim(footprint: UInt64, ceiling: UInt64,
                                       lastTrim: TimeInterval?, now: TimeInterval) -> Bool {
        guard footprint > ceiling else { return false }
        guard let lastTrim else { return true }
        return now - lastTrim >= AppConfig.engineMemoryTrimIntervalSeconds
    }

    /// След процесса (phys_footprint — то, по чему судит jetsam), байты.
    nonisolated static func footprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}
