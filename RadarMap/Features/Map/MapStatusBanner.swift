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
    /// Открыть приборку. Без сети она — единственный экран, который рисуется
    /// целиком локально, и предложить её честнее, чем оставить человека
    /// смотреть на серый прямоугольник вместо карты.
    var onOpenDashboard: (() -> Void)?
    /// Что уже закрыли руками. В памяти сцены, а не в Storage: состояния
    /// недолгие, а лишний ключ в настройках — навсегда.
    @State private var dismissed: Set<String> = []
    @State private var isRetrying = false

    private enum Kind {
        case server(RemoteConfig.Message)
        case offline
        case overheated
        case noSpeedLimits

        /// Ключ для «закрыто»: у объявления свой текст, у остальных — вид.
        var id: String {
            switch self {
            case .server(let message): return "server:\(message.title)"
            case .offline:             return "offline"
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
        if arguments.contains("-forceOffline") { return .offline }
        if arguments.contains("-forceNoLimits") { return .noSpeedLimits }
        #endif
        if let message = env.config.banner { return .server(message) }
        if !env.network.isOnline { return .offline }
        if env.thermal.mode.explains { return .overheated }
        if !env.speedLimits.isReady { return .noSpeedLimits }
        return nil
    }

    var body: some View {
        if let status, !dismissed.contains(status.id) {
            banner(for: status)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func banner(for status: Kind) -> some View {
        switch status {
        case .server(let message):
            shell(symbol: "exclamationmark.triangle.fill", tint: Theme.warning,
                  title: message.title, body: message.body, id: status.id)
        case .offline:
            shell(symbol: "wifi.slash", tint: Theme.textSecondary,
                  title: String(localized: "Карта не загружается — нет сети"),
                  body: String(localized: "Камеры предупреждают как обычно: база хранится на телефоне"),
                  id: status.id,
                  action: onOpenDashboard.map { open in
                      (String(localized: "Открыть приборку"), open)
                  })
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
                .font(.system(size: 18, weight: .semibold))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let body, !body.isEmpty {
                    Text(body)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let (label, perform) = action {
                    Button(isRetrying ? String(localized: "Загружаю…") : label, action: perform)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .disabled(isRetrying)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            Button {
                withMotion(.easeOut(duration: 0.2)) { _ = dismissed.insert(id) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .tapTarget()         // палец за рулём крупнее крестика
            }
            .accessibilityLabel(Text("Закрыть объявление"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerMedium)
                .stroke(tint.opacity(0.35), lineWidth: 1)
        )
    }
}
