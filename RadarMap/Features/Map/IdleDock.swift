//
//  IdleDock.swift
//  RadarMap
//
//  Низ главного экрана без поездки (этап 45, вариант A дизайнера, выбор
//  владельца 05.11): поле «Куда едем?» 56 pt и квадрат «Итоги», под ними
//  чипы «Домой · 25 мин», «На работу» и звезда «Мои места».
//
//  До 45 «куда» была одной из пяти равных кнопок дока, а строка «Домой»
//  появлялась над ними только при уверенной догадке — главного на экране не
//  было. У Яндекс Навигатора и Apple Maps главное одно: поле поиска внизу и
//  Дом/Работа строкой с временем. «Итоги» — квадратом рядом: это экран-
//  награда, прятать его в «…» нельзя. Остальное (Рядом, Добавить камеру,
//  Настройки, слои карты) — плитки круга «…» в колонке справа, те же, что в
//  поездке.
//
//  Маршрута на догадку здесь нет: время по дорогам требует сходить в сеть за
//  маршрутом, которого человек не просил. «Сейчас ~44 мин» — из своей истории
//  этим путём в этот час и пробок now.json, скачанного целиком (DestinationGuess):
//  дом и работа на сервер не уходят.
//

import CoreLocation
import SwiftUI

struct IdleDock: View {
    @Environment(AppEnvironment.self) private var env
    let onSearch: () -> Void
    let onStats: () -> Void
    /// Маршрут к месту — тот же путь, что у поиска.
    let onRoute: (CLLocationCoordinate2D, String) -> Void
    let onMyPlaces: () -> Void
    /// Запасной старт, когда поездка начинается сама (автостарт, «умный»);
    /// nil — ручной старт: тогда над доком жёлтая «Начать поездку».
    var onStartTrip: (() -> Void)? = nil

    var body: some View {
        let guess = Self.guess(env)
        IdleDockContent(chips: chips(guess),
                        guessSpoken: guess.map { guess in
                            [guess.kind.suggestionTitle, guess.spokenUsualText, guess.placeTitle]
                                .compactMap { $0 }.joined(separator: ", ")
                        },
                        onSearch: onSearch, onStats: onStats,
                        onChip: { chip in
                            if let place = chip.place {
                                onRoute(CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon),
                                        place.title ?? chip.kind.title)
                            } else {
                                // Места нет ни заданного, ни выученного — задать его, а не пустота.
                                onMyPlaces()
                            }
                        },
                        onMyPlaces: onMyPlaces, onStartTrip: onStartTrip,
                        onStopSuggesting: { env.settings.destinationSuggestions = false })
            // «Сейчас ~44 мин»: при появлении догадки, на новых пробках и
            // профиле и раз в 2 мин, пока она на экране. Пересчёт — только
            // если ключ сменился (AppEnvironment.refreshDepartureEstimates).
            .task(id: EstimateTrigger(traffic: env.traffic.revision, book: env.commuteProfiles.revision,
                                      guessed: guess != nil)) {
                guard guess != nil else { return }
                while !Task.isCancelled {
                    env.refreshDepartureEstimates()
                    await Task.pause(seconds: AppConfig.commuteEstimateTickSeconds)
                }
            }
    }

    private struct EstimateTrigger: Equatable {
        let traffic: Int
        let book: Int
        let guessed: Bool
    }

    private func chips(_ guess: DestinationGuess?) -> [DestinationChips.Chip] {
        let settings = env.settings
        var manual: [FrequentPlaces.Kind: DestinationChips.Place] = [:]
        for (kind, slot) in [(FrequentPlaces.Kind.home, PlaceSlot.home), (.work, .work)] {
            if let place = settings.place(for: slot) {
                manual[kind] = DestinationChips.Place(lat: place.lat, lon: place.lon, title: place.title)
            }
        }
        return DestinationChips.make(
            manual: manual,
            learned: settings.destinationSuggestions ? env.learnedPlaces : [],
            guess: guess.map { ($0.kind, $0.estimate?.seconds ?? $0.usual ?? $0.crowdUsual) },
            here: env.location.currentCoordinate.map { ($0.latitude, $0.longitude) })
    }

    /// Уверенная догадка «куда сейчас» — общая с машиной (DestinationGuess):
    /// ручные места старше выученных. Её же спрашивает предложение карты
    /// без интернета, чтобы не встать третьей карточкой (5.9).
    static func guess(_ env: AppEnvironment) -> DestinationGuess? {
        guard env.settings.destinationSuggestions,
              !env.location.isTripActive, !env.route.isActive else { return nil }
        return env.destinationGuess(now: Date())
    }
}

/// Сам док — без окружения приложения (превью на 375 pt).
struct IdleDockContent: View {
    let chips: [DestinationChips.Chip]
    /// Догадка словами для VoiceOver; nil — догадки нет.
    var guessSpoken: String? = nil
    let onSearch: () -> Void
    let onStats: () -> Void
    let onChip: (DestinationChips.Chip) -> Void
    let onMyPlaces: () -> Void
    var onStartTrip: (() -> Void)? = nil
    let onStopSuggesting: () -> Void

    /// Высота поля и квадрата: главное действие экрана, по нему бьют не глядя.
    static let fieldHeight: CGFloat = 56

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                searchField
                statsSquare
            }
            HStack(spacing: 8) {
                ForEach(chips) { chip in chipButton(chip) }
                Spacer(minLength: 0)
                circleButton(Icon.myPlaces, tint: Theme.accent, label: "Мои места", action: onMyPlaces)
                if let onStartTrip {
                    circleButton("play.fill", tint: Theme.textPrimary, label: "Начать поездку",
                                 touch: .primary, action: onStartTrip)
                }
            }
        }
        .padding(8)
        // Сплошная панель, а не стекло (решение 13.10): карта под доком в
        // покое всё равно живёт, и стекло пересчитывало бы размытие на
        // каждом её кадре; к тому же сквозь него просвечивали подписи улиц.
        .liftedBackground(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous)
            .strokeBorder(Theme.edgePanel, lineWidth: 1))
    }

    // MARK: - Поле и «Итоги»

    private var searchField: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cornerControl, style: .continuous)
        return Button(action: onSearch) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.rounded(19, .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Куда едем?")
                    .font(.rounded(17, .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: Self.fieldHeight)
            .background(Theme.quietFill, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(PressableStyle())
        .accessibilityHint(Text("Поиск адреса и мест"))
    }

    private var statsSquare: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cornerControl, style: .continuous)
        return Button(action: onStats) {
            VStack(spacing: 3) {
                Image(systemName: "chart.bar.fill")
                    .font(.rounded(19, .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Итоги")
                    .font(.rounded(12, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 2)
            .frame(width: Self.fieldHeight, height: Self.fieldHeight)
            .background(Theme.quietFill, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: - Чипы «Домой» / «На работу»

    private func chipButton(_ chip: DestinationChips.Chip) -> some View {
        let title = [chip.kind.suggestionTitle,
                     chip.minutes.map { Formatting.unbreakable(Formatting.duration(Double($0) * 60)) }]
            .compactMap { $0 }.joined(separator: " · ")
        return Button { onChip(chip) } label: {
            HStack(spacing: 6) {
                Image(systemName: chip.kind.symbol)
                    .font(.rounded(13, .bold))
                Text(verbatim: title)
                    .font(.rounded(15, .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(chip.guessed ? Theme.onAccentFill : Theme.textPrimary)
            .padding(.horizontal, 14)
            .frame(minHeight: Theme.controlSize)
            .background(chip.guessed ? AnyShapeStyle(Theme.accentFill) : AnyShapeStyle(Theme.quietFill),
                        in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        // Уже здесь — бледный, но на своём месте (бледнит стиль).
        .disabled(chip.isHere)
        .layoutPriority(chip.guessed ? 1 : 0)
        // Голосом — словами: «Домой, сейчас около 44 минут», а не «тильда 44 мин».
        .accessibilityLabel(Text(verbatim: chip.guessed ? (guessSpoken ?? title) : title))
        .accessibilityHint(chip.place == nil ? Text("Задать место") : Text("Маршрут сюда"))
        .modifier(GuessMenu(isGuess: chip.guessed, onStopSuggesting: onStopSuggesting))
    }

    private func circleButton(_ symbol: String, tint: Color, label: LocalizedStringKey,
                              touch: TouchRole = .regular, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.rounded(17, .bold))
                .foregroundStyle(tint)
                .frame(width: Theme.controlSize, height: Theme.controlSize)
                .background(Theme.quietFill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(touch))
        .accessibilityLabel(Text(label))
    }
}

/// «Не предлагать» у синего чипа догадки — долгим нажатием и действием
/// VoiceOver; вернуть можно в Настройках, там же объяснено, откуда
/// приложение это знает.
private struct GuessMenu: ViewModifier {
    let isGuess: Bool
    let onStopSuggesting: () -> Void

    func body(content: Content) -> some View {
        if isGuess {
            content
                .accessibilityAction(named: Text("Не предлагать"), onStopSuggesting)
                .contextMenu {
                    Button(action: onStopSuggesting) {
                        Label("Не предлагать", systemImage: "bell.slash")
                    }
                }
        } else {
            content
        }
    }
}

// MARK: - Превью: SE (375 pt), ru/uz, день/ночь

private struct IdleDockPreview: View {
    let locale: String
    let scheme: ColorScheme

    var body: some View {
        let place = DestinationChips.Place(lat: 41.3, lon: 69.2, title: nil)
        VStack(spacing: 16) {
            Spacer()
            IdleDockContent(chips: [.init(kind: .home, place: place, guessed: true, minutes: 25),
                                    .init(kind: .work, place: place, guessed: false, minutes: nil)],
                            onSearch: {}, onStats: {}, onChip: { _ in }, onMyPlaces: {},
                            onStartTrip: {}, onStopSuggesting: {})
            IdleDockContent(chips: [.init(kind: .home, place: nil, guessed: false, minutes: nil),
                                    .init(kind: .work, place: nil, guessed: false, minutes: nil)],
                            onSearch: {}, onStats: {}, onChip: { _ in }, onMyPlaces: {},
                            onStopSuggesting: {})
        }
        .padding(16)
        .frame(width: 375, height: 420)
        .background(Theme.background)
        .environment(\.locale, Locale(identifier: locale))
        .environment(\.colorScheme, scheme)
    }
}

#Preview("SE · ru · день") { IdleDockPreview(locale: "ru", scheme: .light) }
#Preview("SE · ru · ночь") { IdleDockPreview(locale: "ru", scheme: .dark) }
#Preview("SE · uz · день") { IdleDockPreview(locale: "uz", scheme: .light) }
#Preview("SE · uz · ночь") { IdleDockPreview(locale: "uz", scheme: .dark) }
