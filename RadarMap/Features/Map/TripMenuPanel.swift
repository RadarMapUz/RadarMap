//
//  TripMenuPanel.swift
//  RadarMap
//
//  Меню «…» плитками 3 × 2 (на стоянке 3 × 3) — в слое меню над картой
//  (MapScreen+Popovers), над нижними панелями (этап 45, вариант A).
//
//  Не системный `Menu` и не лист: те живут в своём окне поверх всего и
//  накрыли бы карточку камеры. Слой меню лежит ПОД предупреждением о камере,
//  а подъехали к камере — меню закрывается само (MapPopover.Event.cameraAlert).
//  Места плиток — TripMenuSlots: неприменимая бледнеет, а не исчезает.
//

import SwiftUI

struct TripMenuPanel: View {
    let tiles: [TripMenuSlots.Tile]
    /// Свой вид топлива для «… рядом» без маршрута (АЗС, Метан, Зарядка).
    var stopKind: Venue.Kind = .fuel
    /// Символ «По пути» по виду машины (заправка или зарядка).
    var alongSymbol = "fuelpump.fill"
    let onPick: (TripMenuSlots.Action) -> Void
    let onClose: () -> Void

    /// Открыт короткий выбор «Поделиться»: прибытием или «Еду домой».
    @State private var shareChoice: (arrivalEnabled: Bool, sharing: Bool)?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            MapPopoverHeader(title: shareChoice == nil ? "Ещё" : "Поделиться", onClose: onClose)
                .padding(.trailing, -6)
            if let choice = shareChoice {
                shareChoiceRow(choice)
            } else {
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(rows.indices, id: \.self) { index in
                        GridRow {
                            ForEach(rows[index]) { tile in tileButton(tile) }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 4)
        // Сплошная, как все панели над живой картой: стекло пересчитывало бы
        // размытие каждый кадр.
        .liftedBackground(Theme.surface, in: shape)
        .overlay(shape.strokeBorder(Theme.edgePanel, lineWidth: 1))
        .mapPopoverCard(activity: ActivityKey(tiles: tiles.count, choosing: shareChoice != nil), onClose: onClose)
    }

    private struct ActivityKey: Equatable {
        let tiles: Int
        let choosing: Bool
    }

    /// Две плитки вместо сетки: «Поделиться прибытием» (или «Не делиться») и
    /// «Еду домой», и «Назад» к плиткам.
    private func shareChoiceRow(_ choice: (arrivalEnabled: Bool, sharing: Bool)) -> some View {
        let arrival: TripMenuSlots.Action = choice.sharing ? .stopSharing : .shareArrival
        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                tileButton(.init(slot: .search, action: .back, enabled: true))
                tileButton(.init(slot: .myPlaces, action: arrival, enabled: choice.arrivalEnabled))
                tileButton(.init(slot: .along, action: .goingHome, enabled: true))
            }
        }
    }

    private var rows: [[TripMenuSlots.Tile]] {
        stride(from: 0, to: tiles.count, by: 3).map { Array(tiles[$0..<min($0 + 3, tiles.count)]) }
    }

    private func tileButton(_ tile: TripMenuSlots.Tile) -> some View {
        let face = Self.face(tile.action, stopKind: stopKind, alongSymbol: alongSymbol)
        return Button { pick(tile.action) } label: {
            VStack(spacing: 6) {
                Image(systemName: face.symbol)
                    .font(.dense(21, .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(height: 26)
                face.title
                    .font(.dense(12, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 76)
            .padding(.horizontal, 4)
            .background(Theme.quietFill,
                        in: RoundedRectangle(cornerRadius: Theme.cornerControl, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerControl, style: .continuous))
        }
        // Бледнеет стилем (PressableStyle) — своей прозрачности не добавлять.
        .buttonStyle(PressableStyle())
        .disabled(!tile.enabled)
        .accessibilityLabel(face.title)
    }

    private func pick(_ action: TripMenuSlots.Action) {
        switch action {
        case .shareChoice(let arrivalEnabled, let sharing):
            withMotion(Motion.standard) { shareChoice = (arrivalEnabled, sharing) }
        case .back:
            withMotion(Motion.standard) { shareChoice = nil }
        default:
            onPick(action)
        }
    }

    /// Значок и подпись плитки по её действию.
    static func face(_ action: TripMenuSlots.Action, stopKind: Venue.Kind,
                     alongSymbol: String) -> (symbol: String, title: Text) {
        // Text с ключом каталога, а не готовая строка: превью и экран идут
        // за языком окружения.
        switch action {
        case .search:        return ("magnifyingglass", Text("Поиск"))
        case .myPlaces:      return (Icon.myPlaces, Text("Мои места"))
        case .alongRoute:    return (alongSymbol, Text("По пути"))
        case .nearbyStops:   return (stopKind.symbol, Text("\(stopKind.title) рядом"))
        case .routeCameras:  return (Icon.cameras, Text("Камеры впереди"))
        case .nearbyCameras: return (Icon.cameras, Text("Ближайшие камеры"))
        case .shareArrival:  return ("square.and.arrow.up", Text("Поделиться прибытием"))
        case .shareChoice:   return ("square.and.arrow.up", Text("Поделиться"))
        case .back:          return ("chevron.backward", Text("Назад"))
        case .stopSharing:   return ("person.crop.circle.badge.xmark", Text("Не делиться"))
        case .goingHome:     return ("house.fill", Text("Еду домой"))
        case .mapPanel:      return ("square.3.layers.3d", Text("Карта"))
        case .stats:         return ("chart.bar.fill", Text("Итоги"))
        case .addCamera:     return (Icon.ownCamera, Text("Добавить камеру"))
        case .settings:      return ("gearshape.fill", Text("Настройки"))
        }
    }
}

/// Плитки «Ещё» по состоянию приложения. Отдельной вью: «стоим ли» читает
/// скорость, которая пишется каждым фиксом (ARCHITECTURE.md, правило 13).
struct TripMenuHost: View {
    @Environment(AppEnvironment.self) private var env
    let onPick: (TripMenuSlots.Action) -> Void
    let onClose: () -> Void

    /// Третий ряд — с гистерезисом (TripMenuSlots.parked); nil — ещё не решено.
    @State private var parked: Bool?

    var body: some View {
        let speed = env.location.speedKmh
        return TripMenuPanel(tiles: tiles,
                      stopKind: env.settings.vehicleEnergy.stops.first ?? .fuel,
                      alongSymbol: AlongRouteText.symbol(env.settings.vehicleEnergy),
                      onPick: onPick, onClose: onClose)
            .onChange(of: speed, initial: true) { _, now in
                let next = TripMenuSlots.parked(speedKmh: now,
                                                wasParked: parked ?? TripScreenLayout.tripMenuShowsParkedItems(speedKmh: now))
                if next != parked { parked = next }
            }
    }

    private var tiles: [TripMenuSlots.Tile] {
        let sharing = env.etaShare.isSharing
        let location = env.location
        return TripMenuSlots.tiles(.init(
            hasRoute: env.route.isActive,
            isSharingArrival: sharing,
            canShareArrival: !sharing && env.etaShare.isAvailable,
            offersGoingHome: FamilyShare.offersGoingHome(env.family.circle,
                                                         isTripActive: location.isTripActive,
                                                         isPassenger: location.isPassengerSession,
                                                         pausedThisTrip: env.family.pausedThisTrip,
                                                         headingHome: env.family.isHeadingHome, now: Date()),
            parked: parked ?? TripScreenLayout.tripMenuShowsParkedItems(speedKmh: location.speedKmh)))
    }
}

// MARK: - Превью: SE (375 pt), ru/uz, день/ночь

private struct TripMenuPanelPreview: View {
    let locale: String
    let scheme: ColorScheme

    var body: some View {
        VStack(spacing: 16) {
            TripMenuPanel(tiles: TripMenuSlots.tiles(.init(hasRoute: true, canShareArrival: true)),
                          onPick: { _ in }, onClose: {})
            TripMenuPanel(tiles: TripMenuSlots.tiles(.init(parked: true)),
                          onPick: { _ in }, onClose: {})
        }
        .padding(16)
        .frame(width: 375)
        .background(Theme.background)
        .environment(\.locale, Locale(identifier: locale))
        .environment(\.colorScheme, scheme)
    }
}

#Preview("SE · ru · день") { TripMenuPanelPreview(locale: "ru", scheme: .light) }
#Preview("SE · ru · ночь") { TripMenuPanelPreview(locale: "ru", scheme: .dark) }
#Preview("SE · uz · день") { TripMenuPanelPreview(locale: "uz", scheme: .light) }
#Preview("SE · uz · ночь") { TripMenuPanelPreview(locale: "uz", scheme: .dark) }
