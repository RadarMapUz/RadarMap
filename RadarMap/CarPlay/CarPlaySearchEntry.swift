//
//  CarPlaySearchEntry.swift
//  RadarMap
//
//  Вход в поиск адреса в машине: что стоит в баре, что в сетке «Куда», что
//  отвечает касание на стоянке и на ходу.
//
//  Владелец 09.11: «поиска в карплейе нет, кнопки там нету». Лупы не было в
//  осмотре и на выборе маршрута, а плитка «Поиск» гасла, пока машина
//  ограничивает клавиатуру, и на светофоре выглядела отсутствующей. Правило:
//  лупа есть везде, где можно выбрать цель, а запрещённое на ходу действие
//  отвечает причиной и альтернативой, а не серой кнопкой.
//
//  Чистая логика без CarPlay; покрыто CarPlaySearchEntryTests.
//

import Foundation

nonisolated enum CarPlaySearchEntry {

    // MARK: - Бар

    struct Screen: Equatable, Sendable {
        var tripActive: Bool
        var routeActive: Bool
        var panning: Bool
        var previewing: Bool
    }

    enum Bar: Hashable, Sendable {
        case trip(active: Bool)
        case sound
        /// Лупа — «Куда».
        case destinations(routeActive: Bool)
        case report
        case panDone
        case cancelPreview
    }

    struct BarLayout: Equatable, Sendable {
        var leading: [Bar]
        var trailing: [Bar]
    }

    /// Сколько кнопок показывает каждая сторона бара (CPBarButtonProviding.h).
    static let barSideLimit = 2

    static func bar(_ screen: Screen) -> BarLayout {
        let search = Bar.destinations(routeActive: screen.routeActive)
        if screen.panning { return BarLayout(leading: [search], trailing: [.panDone]) }
        if screen.previewing { return BarLayout(leading: [.cancelPreview], trailing: [search]) }
        return BarLayout(leading: [.trip(active: screen.tripActive), .sound], trailing: [search, .report])
    }

    /// Открыть «Куда» из осмотра — сначала закрыть осмотр: шаблон поверх его
    /// анимации CarPlay мог бы отклонить.
    enum Open: Equatable, Sendable { case now, afterClosingPanning }

    static func open(panning: Bool) -> Open { panning ? .afterClosingPanning : .now }

    /// Экран едет — второе касание пропускаем; ответа системы может не быть,
    /// поэтому замок отпускает и время.
    static func pushAllowed(startedAt: Date?, now: Date, guardSeconds: TimeInterval) -> Bool {
        guard let startedAt else { return true }
        return now.timeIntervalSince(startedAt) >= guardSeconds
    }

    // MARK: - Сетка «Куда»

    enum Tile: Hashable, Sendable {
        case search, cancelRoute, overview, cameras
        case slot(Int), stop(Int), recent(Int)
    }

    /// «Поиск» — всегда первая: одно место в любом состоянии находится вслепую.
    static func grid(routeActive: Bool, slots: Int, stops: Int, recents: Int, limit: Int) -> [Tile] {
        var tiles: [Tile] = [.search]
        if routeActive { tiles += [.cancelRoute, .overview, .cameras] }
        tiles += (0..<slots).map(Tile.slot) + (0..<stops).map(Tile.stop) + (0..<recents).map(Tile.recent)
        return Array(tiles.prefix(limit))
    }

    // MARK: - Касание

    enum SearchTap: Equatable, Sendable { case keyboard, alternatives }

    static func searchTap(keyboardLimited: Bool) -> SearchTap {
        keyboardLimited ? .alternatives : .keyboard
    }

    enum SlotTap: Equatable, Sendable { case route, assign, explain }

    /// Дом/Работа: задано — маршрут; нет — задаём поиском, а без клавиатуры
    /// говорим почему.
    static func slotTap(hasPlace: Bool, keyboardLimited: Bool) -> SlotTap {
        if hasPlace { return .route }
        return keyboardLimited ? .explain : .assign
    }

    enum Pick: Equatable, Sendable { case route, askStopOrReplace }

    /// Найденное место: при идущем маршруте спрашиваем «заехать или новая
    /// цель». На выборе вариантов цель ещё не утверждена — просто заменяем.
    static func pick(routeActive: Bool, previewing: Bool) -> Pick {
        routeActive && !previewing ? .askStopOrReplace : .route
    }

    // MARK: - На ходу

    enum MovingRow: Hashable, Sendable {
        case typeAddress, voice
        case slot(Int), recent(Int), category(Int)
    }

    /// Строки списка «Поиск на ходу». «Ввести адрес» — только когда машина
    /// вернула клавиатуру, пока список открыт.
    static func movingRows(keyboardLimited: Bool, slots: Int, recents: Int,
                           categories: Int, limit: Int) -> [MovingRow] {
        var rows: [MovingRow] = keyboardLimited ? [.voice] : [.typeAddress, .voice]
        rows += (0..<slots).map(MovingRow.slot) + (0..<recents).map(MovingRow.recent)
            + (0..<categories).map(MovingRow.category)
        return Array(rows.prefix(max(0, limit)))
    }

    // MARK: - Запрос и ответ

    /// Сколько строк можно отдать списку: своя норма и предел шаблона (он на
    /// ходу меньше и режет молча).
    static func listLimit(own: Int, maximumItemCount: Int) -> Int { min(own, maximumItemCount) }

    /// Что отправлять в поиск: без краёв и не длиннее предела.
    static func normalized(_ text: String, maxLength: Int) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
    }

    static func isSearchable(_ query: String) -> Bool { query.count >= 2 }

    /// Свои адреса выше, Apple — вторым, но своих не столько, чтобы Apple не
    /// осталось места: он знает то, чего нет в своей книге. Одно место дважды
    /// не показываем, остаётся своё.
    static func merged<Place>(own: [Place], apple: [Place], limit: Int, appleSlots: Int,
                              isSame: (Place, Place) -> Bool) -> [Place] {
        guard limit > 0 else { return [] }
        let others = apple.filter { candidate in !own.contains { isSame($0, candidate) } }
        let reserved = min(others.count, appleSlots, limit)
        let ownShown = own.prefix(max(limit - reserved, 0))
        return Array(ownShown) + others.prefix(limit - ownShown.count)
    }

    enum Empty: Equatable, Sendable { case retry, offline }

    static func empty(online: Bool) -> Empty { online ? .retry : .offline }

    enum ListRequest: Equatable, Sendable { case now, whenReady }

    /// «Найти», пока запрос ещё идёт: ждать ответа, иначе «ничего не нашлось»
    /// про ещё не законченный поиск.
    static func listRequest(searching: Bool) -> ListRequest { searching ? .whenReady : .now }
}

/// Ответ шаблону поиска: CarPlay требует ответить на каждый запрос ровно один раз.
nonisolated final class CarPlaySearchReply<Item> {
    private var send: (([Item]) -> Void)?

    init(_ send: @escaping ([Item]) -> Void) { self.send = send }

    func callAsFunction(_ items: [Item]) {
        send?(items)
        send = nil
    }
}
