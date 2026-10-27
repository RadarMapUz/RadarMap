//
//  CorridorOfferCard.swift
//  RadarMap
//
//  «Карта по пути без интернета» (19.3) — над панелью маршрута и над
//  строкой поездки, пока машина стоит. Когда показывать — решает чистый
//  RouteCorridor; что качать и откуда — RouteCorridorService; здесь вид,
//  ответ и сторож «тронулись».
//

import CoreLocation
import SwiftUI

/// Карточка, если момент тот: длинный маршрут, Wi-Fi, стоим, не спрашивали
/// и есть место — обязательные кнопки колонки справа под неё не уходят.
struct CorridorOfferGate: View {
    @Environment(AppEnvironment.self) private var env
    /// Внизу уже карточка, которая ждёт ответа (итог поездки, прибытие):
    /// больше двух карточек внизу не бывает (5.9) — мегабайты подождут.
    var yields = false
    /// Под стопкой нижний бар (покой): с карточкой он уступает ей место.
    var freesActionBar = false
    /// Просвет колонки, высоты карточки (скрытая копия) и бара — в MapState.
    let map: MapState

    var body: some View {
        if let shown = candidate,
           CorridorOfferPlacement.fits(room: map.columnRoom, cardHeight: map.corridorCardHeight,
                                       shown: map.corridorCardShown,
                                       freed: freesActionBar ? map.actionBarHeight : 0) {
            CorridorOfferCard(offer: shown.offer, key: shown.key)
                .onAppear { map.corridorCardShown = true }
                .onDisappear { map.corridorCardShown = false }
        }
    }

    private var candidate: (offer: RouteCorridor.Offer, key: String)? {
        CorridorOfferBackstage.pending(env).flatMap { pending in
            let situation = RouteCorridor.Situation(
                routeMeters: pending.meters,
                online: env.network.isOnline,
                expensiveNetwork: env.network.isExpensive,
                // В поездке «тронулись» ловит сторож (CorridorOfferBackstage) —
                // по скорости, которую этот гейт не читает (правило 13).
                moving: env.location.isProbablyDriving,
                answered: false,
                questionShown: yields || env.mobile.passQuestion != nil || env.mobile.refineOffer != nil)
            return RouteCorridor.shouldOffer(situation, offer: pending.offer) ? (pending.offer, pending.key) : nil
        }
    }
}

/// Где карточке встать, не загоняя обязательные кнопки колонки справа под
/// себя (правило 14.9: на SE с крупным шрифтом вопрос, «Машина» и «Домой»
/// вместе уже прятали их). Колонка мерит просвет до нижних панелей;
/// карточка встаёт, только если и после неё обязательным хватит мест.
///
/// В покое с маршрутом карточка занимает место нижнего бара — «Поиск»,
/// «Итоги» до ответа подождут: на SE иначе ей не встать нигде, кроме как
/// после «Поехали» (строка поездки ниже панели маршрута втрое). На SE с
/// крупным шрифтом не хватает и так — тогда она ждёт «Поехали».
///
/// Чистое — покрыто RouteCorridorTests.
nonisolated enum CorridorOfferPlacement {

    /// - `room`: просвет колонки сейчас (MapScreen.updateColumnSlots); если
    ///   карточка на экране — уже с ней; nil — не измерен.
    /// - `cardHeight`: высота карточки; nil — не измерена.
    /// - `shown`: карточка сейчас на экране.
    /// - `freed`: высота того, что уступит ей место (нижний бар), 0 — ничего.
    ///
    /// Спрятанная встаёт с запасом `slack`, стоящая уходит, только когда мест
    /// не хватает уже с ней: решение «встать» не обращается в «уйти» на
    /// следующем кадре — без мигания.
    static func fits(room: CGFloat?, cardHeight: CGFloat?, shown: Bool, freed: CGFloat = 0,
                     fixed: Int = AppConfig.mapColumnFixedButtons,
                     spacing: CGFloat = AppConfig.bottomStackSpacing, slack: CGFloat = 2) -> Bool {
        guard let room, let cardHeight else { return false }
        let freedSpace = freed > 0 ? freed + spacing : 0
        let after = shown ? room : room - (cardHeight + spacing) + freedSpace - slack
        return (TripScreenLayout.columnSlots(room: after) ?? 0) >= fixed
    }
}

/// Закулисье карточки — фоном нижней стопки, места в вёрстке не занимает:
///
/// - сторож «тронулись»: машина поехала — на этом маршруте больше не
///   спрашиваем (иначе скрытая на ходу карточка всплывала бы на каждом
///   светофоре). Скорость читается только в поездке и только пока вопрос
///   открыт: после ответа подписки на тик нет вовсе;
/// - скрытая копия карточки меряет её высоту, чтобы гейт решал «поместится
///   ли», ещё не показав её, — без прыжка панели маршрута вверх и обратно.
struct CorridorOfferBackstage: View {
    @Environment(AppEnvironment.self) private var env
    let map: MapState

    /// Вопрос открыт: длинный маршрут, коридор посчитан для этой цели, ответа
    /// не было и есть что качать.
    static func pending(_ env: AppEnvironment) -> (offer: RouteCorridor.Offer, key: String, meters: Double)? {
        let route = env.route
        guard let variant = route.selected, RouteCorridor.isLong(variant.distance),
              let destination = route.destinationCoordinate else { return nil }
        let key = RouteCorridor.routeKey(destination: destination)
        // Ответили — дальше ни загрузки, ни сеть не читаем: вью не
        // пересобираются на каждом проценте скачивания.
        guard !env.corridor.answered.contains(key), env.corridor.plan?.key == key,
              let offer = env.corridor.offer(), !offer.isEmpty else { return nil }
        return (offer, key, variant.distance)
    }

    var body: some View {
        let pending = Self.pending(env)
        let moving = pending != nil && isMoving
        ZStack {
            if let pending {
                CorridorOfferCard(offer: pending.offer, key: pending.key)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if abs((map.corridorCardHeight ?? 0) - height) > 0.5 { map.corridorCardHeight = height }
                    }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: Watch(key: pending?.key, moving: moving), initial: true) { _, now in
            if now.moving, let key = now.key { env.corridor.answer(key: key) }
        }
    }

    private struct Watch: Equatable {
        let key: String?
        let moving: Bool
    }

    private var isMoving: Bool {
        env.location.isTripActive
            ? !TripScreenLayout.tripMenuShowsParkedItems(speedKmh: env.location.speedKmh)
            : env.location.isProbablyDriving
    }
}

/// Сама карточка: области по ходу, размер, «Скачать» и крестик.
struct CorridorOfferCard: View {
    @Environment(AppEnvironment.self) private var env
    let offer: RouteCorridor.Offer
    let key: String

    var body: some View {
        // Одной строкой — только если помещается целиком; иначе две:
        // заголовок и области во всю ширину, «Скачать» ниже (как у
        // OfflineOfferCard: на SE с крупным шрифтом одна строка резала всё).
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                icon
                texts(wraps: false)
                Spacer(minLength: 0)
                closeButton
                downloadButton
            }
            VStack(alignment: .trailing, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    icon
                    texts(wraps: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    closeButton
                }
                downloadButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .liftedBackground(Theme.surface,
                          in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
            .stroke(Theme.stroke, lineWidth: 1))
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
    }

    private var icon: some View {
        Image(systemName: "arrow.down.circle.fill")
            .font(.rounded(18, .bold))
            .foregroundStyle(Theme.accent)
            .frame(width: 36, height: 36)
            .background(Theme.quietFill, in: Circle())
            .accessibilityHidden(true)
    }

    /// Области по ходу короткими именами и граф трасс, если он нужен.
    private var parts: [String] {
        let language = OfflineMapsView.language(env.settings.appLanguage)
        var names = RouteCorridor.shortNames(offer.regions.map { $0.title(language: language) })
        if offer.graphBytes != nil { names.append(String(localized: "маршрут без сети")) }
        return names
    }

    private func texts(wraps: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Карта по пути без интернета")
                .font(.rounded(15, .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(wraps ? nil : 1)
                .fixedSize(horizontal: false, vertical: wraps)
            Text(verbatim: parts.joined(separator: " · "))
                .font(.rounded(12))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(wraps ? nil : 1)
                .fixedSize(horizontal: false, vertical: wraps)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: String(localized: "Карта по пути без интернета") + ". "
                                 + parts.joined(separator: ", ")))
    }

    private var closeButton: some View {
        Button {
            withMotion(Motion.standard) { env.corridor.answer(key: key) }
        } label: {
            Image(systemName: "xmark")
                .font(.rounded(14, .bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 32, height: 32)
                .background(Theme.textTertiary.opacity(0.14), in: Circle())
        }
        .buttonStyle(.plain)
        .tapTarget()
        .accessibilityLabel(Text("Не сейчас"))
    }

    private var downloadButton: some View {
        Button {
            guard let points = env.route.selected?.points else { return }
            withMotion(Motion.standard) { env.corridor.download(offer, key: key, points: points) }
        } label: {
            // Синяя, не жёлтая: жёлтая на экране одна — «Поехали».
            Text(String(format: String(localized: "Скачать · %@"),
                        Formatting.unbreakable(OfflineMapsView.size(offer.totalBytes))))
                .font(.rounded(15, .bold))
                .foregroundStyle(Theme.onAccentFill)
                .fixedSize()
                .padding(.horizontal, 16)
                .frame(minHeight: Theme.controlSize)
                .background(Theme.accentFill, in: Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(Text(String(format: String(localized: "Скачать карту по пути, %@"),
                                        Self.spokenSize(offer.totalBytes))))
    }

    /// «96 мегабайт» словами — VoiceOver читает «МБ» буквами.
    static func spokenSize(_ bytes: Int64, locale: Locale = NumberFormat.locale) -> String {
        let megabytes = max(1, (Double(bytes) / 1_000_000).rounded())
        return Measurement(value: megabytes, unit: UnitInformationStorage.megabytes)
            .formatted(.measurement(width: .wide, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(0)))
                .locale(locale))
    }
}

extension MapScreen {
    /// Когда пересчитывать коридор: новая линия маршрута или Wi-Fi вместо
    /// сотовой (по Wi-Fi коридор докачивает файлы заведений).
    struct CorridorPrepareKey: Equatable {
        let line: ObjectIdentifier?
        let wifi: Bool
    }

    var corridorPrepareKey: CorridorPrepareKey {
        CorridorPrepareKey(line: env.route.selected.map { ObjectIdentifier($0.polyline) },
                           wifi: env.network.isOnline && !env.network.isExpensive)
    }
}
