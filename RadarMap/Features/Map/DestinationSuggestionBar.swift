//
//  DestinationSuggestionBar.swift
//  RadarMap
//
//  «Домой» / «На работу» — одна строка вместо двух пустых кругов.
//
//  Круги Дом и Работа стояли на экране всегда: заданные — как две иконки,
//  незаданные — как два серых кружка с плюсом, то есть как невыполненное
//  задание от приложения человеку. Но приложение знает распорядок лучше:
//  куда машина приезжает вечером и куда уезжает утром буднего дня, видно из
//  истории поездок (FrequentPlaces).
//
//  Поэтому строка живёт по правилу «нечего сказать — ничего не показываю»:
//  нет уверенной догадки, стоим уже в этом месте, выключено в настройках —
//  элемента на экране просто нет, и низ карты чистый.
//
//  Маршрута на догадку здесь нет: чтобы узнать время по дорогам, нужно сходить
//  в сеть за маршрутом, которого человек не просил. Тап строит его
//  по-настоящему — и тогда всё показывает панель маршрута. Зато «сейчас ~44
//  мин» — из СВОЕЙ истории поездок этим путём в этот час (CommuteEstimate) и
//  пробок now.json, скачанного целиком: цель на сервер не уходит. Нет профиля
//  на этот час — «обычно 44 мин» за месяц (Commute).
//
//  Заданный вручную адрес (Настройки → Мои места) старше выученного: если
//  человек сказал, где его дом, спорить с ним нельзя.
//

import SwiftUI
import CoreLocation

struct DestinationSuggestionBar: View {
    @Environment(AppEnvironment.self) private var env
    /// Строит маршрут — тот же путь, что у поиска и «Повторить маршрут».
    let onRoute: (CLLocationCoordinate2D, String) -> Void

    var body: some View {
        if let target = suggestion {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onRoute(target.coordinate, target.title)
            } label: {
                HStack(spacing: 12) {
                    IconBadge(symbol: target.kind.symbol,
                              tint: target.kind == .work ? Theme.Icon.work : Theme.Icon.home, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(target.kind.suggestionTitle)
                            .font(.rounded(15, .bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(target.subtitle)
                            .font(.rounded(11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                        .font(.rounded(20))
                        .foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                // Сплошная панель, как бар под ней: сквозь стекло просвечивали
                // подписи улиц (снимок 12.10), а размытие над живой картой
                // пересчитывается на каждом её кадре.
                .liftedBackground(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                    .strokeBorder(Theme.edgePanel, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .transition(.move(edge: .bottom).combined(with: .opacity))
            // «Сейчас ~44 мин»: при появлении строки и на каждых новых пробках
            // (раз в 2 мин, пока смотрят карту); сам расчёт троттлится в env.
            .task(id: env.traffic.revision) { env.refreshDepartureEstimates() }
            // Долгий тап — выключить. Вернуть можно в Настройках, там же
            // объяснено, откуда приложение это знает.
            .contextMenu {
                Button {
                    env.settings.destinationSuggestions = false
                } label: {
                    Label("Не предлагать", systemImage: "bell.slash")
                }
            }
        }
    }

    /// Куда предлагаем ехать прямо сейчас — общая догадка с машиной
    /// (DestinationGuess): ручные места старше выученных, «обычно» — из своих
    /// поездок.
    private struct Target {
        let kind: FrequentPlaces.Kind
        let coordinate: CLLocationCoordinate2D
        let subtitle: String
        var title: String { kind.title }
    }

    private var suggestion: Target? {
        guard let guess = Self.guess(env) else { return nil }
        return Target(kind: guess.kind, coordinate: guess.coordinate, subtitle: guess.subtitle)
    }

    /// Будет ли строка на экране — её же спрашивает предложение офлайн-карты,
    /// чтобы не встать третьей карточкой (5.9).
    static func isShown(_ env: AppEnvironment) -> Bool { guess(env) != nil }

    private static func guess(_ env: AppEnvironment) -> DestinationGuess? {
        guard env.settings.destinationSuggestions,
              !env.location.isTripActive, !env.route.isActive else { return nil }
        return env.destinationGuess(now: Date())
    }
}
