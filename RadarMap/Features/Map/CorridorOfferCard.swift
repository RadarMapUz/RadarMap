//
//  CorridorOfferCard.swift
//  RadarMap
//
//  «Карта по пути без интернета» (19.3) — над панелью маршрута и в панели
//  поездки, пока машина стоит. Когда показывать — решает чистый
//  RouteCorridor; что качать и откуда — RouteCorridorService; вид и ответ —
//  вопрос на ходу (RoadPrompts, этап 45); здесь место, замер и сторож
//  «тронулись».
//

import CoreLocation
import SwiftUI

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
            if pending != nil, let model = RoadPromptContent.corridor(env) {
                RoadPromptPanel { RoadPromptCard(model: model) }
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
