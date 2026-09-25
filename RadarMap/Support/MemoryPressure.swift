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

import os
import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
enum MemoryPressure {

    /// Сколько раз система просила освободить память за сеанс. Идёт в
    /// суточный отчёт: без этого числа «приложение вылетает» остаётся
    /// ощущением, а не событием, у которого есть частота.
    private(set) static var warnings = 0

    /// Кого будить на предупреждение. Слабые ссылки: подписчик уходит вместе
    /// со своим экраном, отписываться вручную не нужно.
    private static var subscribers: [() -> Bool] = []

    /// Зарегистрировать уборку. Замыкание возвращает false, когда его хозяин
    /// уже мёртв, — тогда запись выбрасывается.
    static func onWarning<Owner: AnyObject>(_ owner: Owner,
                                            _ clean: @escaping (Owner) -> Void) {
        start()
        subscribers.append { [weak owner] in
            guard let owner else { return false }
            clean(owner)
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

    /// Освободить всё, что можно построить заново.
    static func relieve() {
        warnings += 1
        // Кэш сетевых ответов: любая его строка берётся из сети повторно, и
        // ни одна не нужна для предупреждения о камере.
        URLCache.shared.removeAllCachedResponses()
        subscribers = subscribers.filter { $0() }
        Log.app.notice("память: система просила освободить, чистка выполнена (\(warnings, privacy: .public)-й раз за сеанс)")
    }
}
