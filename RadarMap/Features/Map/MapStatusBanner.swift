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
    @State private var showOfflineMaps = false

    private enum Kind {
        case server(RemoteConfig.Message)
        case offline(OfflineNotice)
        case overheated
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
                }
            case .overheated:          return "overheated"
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
        if arguments.contains("-forceOffline") { return .offline(offlineNotice(online: false) ?? .general) }
        if arguments.contains("-forceNoLimits") { return .noSpeedLimits }
        #endif
        if let message = env.config.banner { return .server(message) }
        if let notice = offlineNotice(online: env.network.isOnline) { return .offline(notice) }
        if env.thermal.mode.explains { return .overheated }
        if !env.speedLimits.isReady { return .noSpeedLimits }
        return nil
    }

    /// Какую плашку «нет связи» показать. Координата читается только без
    /// связи: со связью плашка не должна перерисовываться на каждом GPS-тике.
    private func offlineNotice(online: Bool) -> OfflineNotice? {
        guard !online else { return nil }
        let here = modernMap ? env.location.currentCoordinate : nil
        let files = here.flatMap { env.offlineMaps.offlineFiles(at: $0) }
        return OfflineNotice.resolve(online: online, modernMap: modernMap,
                                     hasRegionFiles: files != nil)
    }

    var body: some View {
        Group {
            if let status, !dismissed.contains(status.id) {
                banner(for: status)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showOfflineMaps) {
            NavigationStack {
                OfflineMapsView()
                    .settingsPage()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Готово") { showOfflineMaps = false }
                        }
                    }
            }
        }
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
            shell(symbol: "wifi.slash", tint: Theme.textSecondary,
                  title: String(localized: "Карта не загружается — нет сети"),
                  body: String(localized: "Камеры предупреждают как обычно: база хранится на телефоне"),
                  id: status.id)
        case .offline(.downloadedRegion):
            shell(symbol: "wifi.slash", tint: Theme.textSecondary,
                  title: String(localized: "Нет связи — карта из скачанной области"),
                  body: nil, id: status.id)
        case .offline(.noMap):
            shell(symbol: "wifi.slash", tint: Theme.textSecondary,
                  title: String(localized: "Нет связи — карта не грузится, камеры предупреждают"),
                  body: nil, id: status.id,
                  action: (String(localized: "Скачать область"), { showOfflineMaps = true }))
        case .overheated:
            shell(symbol: "thermometer.high", tint: Theme.warning,
                  title: String(localized: "Телефон перегрелся"),
                  body: String(localized: "Упростили карту, чтобы не тормозило. Оповещения работают полностью"),
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

    private func shell(symbol: String, tint: Color, title: String, body: String?,
                       id: String, action: (String, () -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.rounded(19, .semibold))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let body, !body.isEmpty {
                    Text(body)
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let (label, perform) = action {
                    // Кнопка, а не подпись: была `.caption` без рамки, ~16 pt
                    // в высоту — промах за рулём значит второй взгляд.
                    Button(action: perform) {
                        Text(isRetrying ? String(localized: "Загружаю…") : label)
                            .font(.rounded(15, .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 14)
                            .frame(minHeight: Theme.controlSize)
                            .background(Theme.accent.opacity(0.12), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(isRetrying)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
            Button {
                withMotion(.easeOut(duration: 0.2)) { _ = dismissed.insert(id) }
            } label: {
                Image(systemName: "xmark")
                    .font(.rounded(12, .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .tapTarget()         // палец за рулём крупнее крестика
            }
            .accessibilityLabel(Text("Закрыть объявление"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous)
                .stroke(tint.opacity(0.35), lineWidth: 1)
        )
    }
}
