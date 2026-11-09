//
//  MapStatusBanner.swift
//  RadarMap
//
//  Одна плашка на все случаи, когда приложение работает не в полную силу.
//
//  Правило здесь одно: молчаливая деградация читается как поломка. Серая карта
//  без объяснения — «приложение сломалось». Урезанные маркеры в жару —
//  «тормозит». Пустые Итоги без лимитов — «ничего не считает». Человек,
//  который понимает причину, открывает окно или ждёт; человек, который не
//  понимает, удаляет приложение и пишет отзыв.
//
//  Показывается ВСЕГДА одна, самая важная: четыре плашки разом закрыли бы
//  карту, ради которой приложение и открыли.
//

import SwiftUI

struct MapStatusBanner: View {
    @Environment(AppEnvironment.self) private var env
    /// На экране новая карта (движок со стилем OpenMapTiles): только она
    /// умеет рисоваться из скачанной области, и только ей есть что предложить.
    var modernMap: Bool = false
    /// Что уже закрыли руками. В памяти сцены, а не в Storage: состояния
    /// недолгие, а лишний ключ в настройках — навсегда.
    @State private var dismissed: Set<String> = []
    @State private var isRetrying = false

    private enum Kind {
        case server(RemoteConfig.Message)
        case offline(OfflineNotice)
        case overheated
        case savingBattery
        case noSpeedLimits

        /// Ключ для «закрыто»: у объявления свой текст, у остальных — вид.
        var id: String {
            switch self {
            case .server(let message): return "server:\(message.title)"
            case .offline(let notice):
                switch notice {
                case .general:          return "offline"
                case .downloadedRegion: return "offline:region"
                case .noMap:            return "offline:none"
                case .serverDown:       return "offline:server"
                case .serverDownRegion: return "offline:server-region"
                }
            case .overheated:          return "overheated"
            case .savingBattery:       return "battery"
            case .noSpeedLimits:       return "limits"
            }
        }
    }

    /// Приоритет сверху вниз. Сообщение сервера первое: оно про то, что часть
    /// приложения намеренно выключена, и это знание отменяет все догадки ниже.
    private var status: Kind? {
        #if DEBUG
        // Перегрев и обрыв связи на симуляторе не воспроизвести, а посмотреть
        // на плашку глазами надо — как и на скриншоты CarPlay (-hideCameraAlert).
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-forceOverheated") { return .overheated }
        if arguments.contains("-forceLowBattery") { return .savingBattery }
        if arguments.contains("-forceOffline") { return .offline(offlineNotice(online: false) ?? .general) }
        if arguments.contains("-forceNoLimits") { return .noSpeedLimits }
        #endif
        // Решает чистая политика (MapStatusPick): в поездке — только сеть.
        let offline = offlineNotice(online: env.network.isOnline)
        switch MapStatusPick.pick(hasServerMessage: env.config.banner != nil,
                                  isOffline: offline != nil,
                                  isOverheated: env.thermal.reason == .heat,
                                  savingBattery: env.thermal.reason == .battery,
                                  limitsReady: env.speedLimits.isReady,
                                  inTrip: inTrip) {
        case .server?:        return env.config.banner.map { .server($0) }
        case .offline?:       return offline.map { .offline($0) }
        case .overheated?:    return .overheated
        case .savingBattery?: return .savingBattery
        case .noSpeedLimits?: return .noSpeedLimits
        case nil:             return nil
        }
    }

    private var inTrip: Bool { env.location.isTripActive }
    /// В поездке — одна строка: пояснение и кнопки ждут остановки.
    private var compact: Bool { MapStatusPick.isCompact(inTrip: inTrip) }

    /// Какую плашку «нет связи» показать. Координата читается только без
    /// связи: со связью плашка не должна перерисовываться на каждом GPS-тике.
    private func offlineNotice(online: Bool) -> OfflineNotice? {
        let serverDown = env.network.isTileServerDown
        guard !online || serverDown else { return nil }
        let here = modernMap ? env.location.currentCoordinate : nil
        let files = here.flatMap { env.offlineMaps.offlineFiles(at: $0) }
        return OfflineNotice.resolve(online: online, modernMap: modernMap,
                                     hasRegionFiles: files != nil, serverDown: serverDown)
    }

    var body: some View {
        Group {
            if let status, !dismissed.contains(status.id) {
                banner(for: status)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    /// Вторая строка офлайн-плашки: что без связи не работает. Граф трасс —
    /// файл на диске, поэтому спрашиваем только на стоянке (в поездке строки нет).
    private var offlineLimits: String? {
        guard !compact else { return nil }
        return env.offlineRoutes.hasGraph
            ? String(localized: "Маршрут — только приблизительный, по трассам. Пробок нет")
            : String(localized: "Маршруты и пробки недоступны без связи")
    }

    @ViewBuilder
    private func banner(for status: Kind) -> some View {
        switch status {
        case .server(let message):
            shell(symbol: "exclamationmark.triangle.fill", tint: Theme.warning,
                  title: message.title, body: message.body, id: status.id)
        case .offline(.general):
            // Кнопки здесь нет намеренно. Раньше стояла «Открыть приборку» —
            // спидометр рисовался без сети целиком, — но он убран, а другого
            // экрана, который честно заменил бы серую карту, у этой подложки
            // нет. Главное плашка и так говорит: камеры предупреждают.
            // В поездке пояснение убирается — заголовок сам говорит главное
            // (ревью 19.10).
            shell(symbol: "wifi.slash", tint: Theme.textSecondary,
                  title: compact ? String(localized: "Нет сети — камеры предупреждают")
                                 : String(localized: "Карта не загружается — нет сети"),
                  body: String(localized: "Камеры предупреждают как обычно: база хранится на телефоне"),
                  id: status.id)
        case .offline(.downloadedRegion):
            shell(symbol: "wifi.slash", tint: Theme.textSecondary,
                  title: String(localized: "Офлайн-режим: карта и камеры работают"),
                  body: offlineLimits, id: status.id)
        case .offline(.noMap):
            shell(symbol: "wifi.slash", tint: Theme.textSecondary,
                  title: String(localized: "Офлайн-режим: камеры работают, карты здесь нет"),
                  body: offlineLimits, id: status.id)
        case .offline(.serverDown):
            shell(symbol: "server.rack", tint: Theme.textSecondary,
                  title: String(localized: "Сервер карты не отвечает — камеры предупреждают"),
                  body: nil, id: status.id)
        case .offline(.serverDownRegion):
            shell(symbol: "server.rack", tint: Theme.textSecondary,
                  title: String(localized: "Сервер карты не отвечает — карта из скачанной области"),
                  body: nil, id: status.id)
        case .overheated:
            shell(symbol: "thermometer.high", tint: Theme.warning,
                  title: String(localized: "Телефон перегрелся"),
                  body: String(localized: "Упростили карту, чтобы не тормозило. Оповещения работают полностью"),
                  id: status.id)
        case .savingBattery:
            // Одна строка и за рулём: заголовок сам говорит главное.
            shell(symbol: "battery.25percent", tint: Theme.warning,
                  title: String(localized: "Экономим батарею"),
                  body: String(localized: "Мало заряда: карта плоская и проще. Оповещения о камерах работают полностью"),
                  id: status.id)
        case .noSpeedLimits:
            shell(symbol: "speedometer", tint: Theme.textSecondary,
                  title: String(localized: "Ограничения скорости не загрузились"),
                  body: String(localized: "Без них не считаются превышения, рейтинг и штрафы"),
                  id: status.id,
                  action: (String(localized: "Повторить"), retryLimits))
        }
    }

    private func retryLimits() {
        guard !isRetrying else { return }
        isRetrying = true
        Task {
            await env.speedLimits.retryDownload()
            isRetrying = false
        }
    }

    private func shell(symbol: String, tint: Color, title: String, body rawBody: String?,
                       id: String, action rawAction: (String, () -> Void)? = nil) -> some View {
        let body = compact ? nil : rawBody
        let action = compact ? nil : rawAction
        return shellContent(symbol: symbol, tint: tint, title: title, body: body,
                            id: id, action: action)
    }

    private func shellContent(symbol: String, tint: Color, title: String, body: String?,
                              id: String, action: (String, () -> Void)?) -> some View {
        StatusBanner(symbol: symbol, tint: tint, title: title, detail: body,
                     action: action.map { StatusBanner.Action(title: $0.0, isBusy: isRetrying,
                                                              perform: $0.1) },
                     onDismiss: { withMotion(Motion.quick) { _ = dismissed.insert(id) } })
    }
}
