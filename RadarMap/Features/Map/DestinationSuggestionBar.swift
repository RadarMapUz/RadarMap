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
//  Времени в пути и числа камер здесь намеренно НЕТ: чтобы их узнать, нужно
//  построить маршрут, то есть сходить в сеть на догадку, которую человек не
//  просил. Тап строит маршрут по-настоящему — и тогда всё это показывает
//  панель маршрута, честно и один раз.
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
                    Image(systemName: target.kind.symbol)
                        .font(.rounded(15, .bold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 36, height: 36)
                        .background(Theme.accent.opacity(0.14), in: Circle())
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
        if let manual = manualPlace(for: place.kind) {
            return Target(kind: place.kind, coordinate: manual.coordinate,
                          subtitle: manual.title)
        }
        return Target(kind: place.kind, coordinate: place.coordinate,
                      subtitle: String(localized: "Ваш обычный маршрут"))
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
