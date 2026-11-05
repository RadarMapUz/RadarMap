//
//  DestinationSuggestionBar.swift
//  RadarMap
//
//  «Домой» / «На работу» — одна строка вместо двух пустых кругов; с этапа 31
//  она верхняя строка дока главного экрана (MapScreen.actionBar).
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
//  на этот час — «обычно 44 мин» за месяц (Commute), а до трёх своих поездок —
//  «обычно ~35 мин (по водителям)» (TypicalTraffic, 8.8.16).
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
                            .font(.rounded(12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.rounded(12, .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                // Строка дока, а не своя карточка (этап 31): своя форма над
                // доком была третьей формой в нижней стопке. Черта снизу
                // отделяет её от ряда кнопок той же панели.
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.stroke).frame(height: 1)
                        .padding(.horizontal, 16)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            // Голосом — словами: «На работу, сейчас около 44 минут», а не
            // «тильда 44 мин».
            .accessibilityLabel(Text(target.spoken))
            .accessibilityHint(Text("Маршрут сюда"))
            // «Не предлагать» живёт в долгом нажатии — у VoiceOver его нет.
            .accessibilityAction(named: Text("Не предлагать")) {
                env.settings.destinationSuggestions = false
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            // «Сейчас ~44 мин»: сразу при появлении строки, на новых пробках и
            // профиле, и раз в 2 мин, пока строка на экране — без пробок
            // (выключены, нет сети) часы идут всё равно. Пересчёт — только
            // если ключ сменился (env).
            .task(id: EstimateTrigger(traffic: env.traffic.revision, book: env.commuteProfiles.revision)) {
                while !Task.isCancelled {
                    env.refreshDepartureEstimates()
                    await Task.pause(seconds: AppConfig.commuteEstimateTickSeconds)
                }
            }
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

    private struct EstimateTrigger: Equatable {
        let traffic: Int
        let book: Int
    }

    /// Куда предлагаем ехать прямо сейчас — общая догадка с машиной
    /// (DestinationGuess): ручные места старше выученных, «обычно» — из своих
    /// поездок.
    private struct Target {
        let kind: FrequentPlaces.Kind
        let coordinate: CLLocationCoordinate2D
        let subtitle: String
        /// Строка целиком для VoiceOver.
        let spoken: String
        var title: String { kind.title }
    }

    private var suggestion: Target? {
        guard let guess = Self.guess(env) else { return nil }
        let spoken = [guess.kind.suggestionTitle, guess.spokenUsualText, guess.placeTitle]
            .compactMap { $0 }.joined(separator: ", ")
        return Target(kind: guess.kind, coordinate: guess.coordinate, subtitle: guess.subtitle,
                      spoken: spoken)
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
