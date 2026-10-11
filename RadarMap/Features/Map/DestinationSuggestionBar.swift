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
//  по-настоящему — и тогда всё показывает панель маршрута. Зато «обычно 44
//  мин» — из СВОЕЙ истории поездок (Commute), без сети и без догадок: так
//  человек ездит туда каждый день.
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
                .background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .transition(.move(edge: .bottom).combined(with: .opacity))
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

    /// Куда предлагаем ехать прямо сейчас.
    private struct Target {
        let kind: FrequentPlaces.Kind
        let coordinate: CLLocationCoordinate2D
        /// Заданный рукой адрес показываем как есть — это ответ на «а точно
        /// туда?»; у выученного места адреса нет, и врать о нём не надо.
        let subtitle: String
        var title: String { kind.title }
    }

    private var suggestion: Target? {
        guard env.settings.destinationSuggestions,
              !env.location.isTripActive, !env.route.isActive else { return nil }
        // Ручные места старше выученных — и в самой подсказке тоже: сначала
        // спрашиваем движок «куда бы сейчас», потом берём лучший адрес.
        guard let place = FrequentPlaces.suggestion(places: places,
                                                    from: env.location.currentCoordinate,
                                                    now: Date())
        else { return nil }
        let usual = usualTime(to: place.kind)
        if let manual = manualPlace(for: place.kind) {
            return Target(kind: place.kind, coordinate: manual.coordinate,
                          subtitle: [manual.title, usual].compactMap { $0 }.joined(separator: " · "))
        }
        return Target(kind: place.kind, coordinate: place.coordinate,
                      subtitle: usual.map { $0.prefix(1).uppercased() + $0.dropFirst() }
                        ?? String(localized: "Ваш обычный маршрут"))
    }

    /// «обычно 44 мин» — медиана своих поездок туда за 30 дней.
    private func usualTime(to kind: FrequentPlaces.Kind) -> String? {
        let direction: Commute.Direction = kind == .work ? .toWork : .toHome
        guard let usual = env.commute.first(where: { $0.direction == direction })?.usual else { return nil }
        return String(format: String(localized: "обычно %@"), Formatting.unbreakable(Formatting.duration(usual)))
    }

    /// Ручные места подмешиваются к выученным: заданный дом делает подсказку
    /// возможной, даже если истории поездок ещё нет (первый день с приложением).
    private var places: [FrequentPlaces.Place] {
        var result = env.learnedPlaces
        for kind in [FrequentPlaces.Kind.home, .work] {
            guard let manual = manualPlace(for: kind) else { continue }
            result.removeAll { $0.kind == kind }
            result.append(FrequentPlaces.Place(kind: kind, lat: manual.lat,
                                               lon: manual.lon,
                                               days: AppConfig.placeMinDistinctDays))
        }
        return result
    }

    private func manualPlace(for kind: FrequentPlaces.Kind) -> SavedPlace? {
        env.settings.place(for: kind == .home ? .home : .work)
    }
}
