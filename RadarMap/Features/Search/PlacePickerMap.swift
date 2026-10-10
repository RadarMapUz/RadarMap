//
//  PlacePickerMap.swift
//  RadarMap
//
//  «Выбрать на карте» — Дом и Работа пальцем, а не словами.
//
//  Поиск по адресу покрывает не всё: дом в махалле без номера в OSM, новый
//  квартал, дача — словами их не найти, а показать на карте можно. Просьба
//  владельца была прямой: «мои места — там выбор по карте нет».
//
//  Жест — как у навигаторов: булавка стоит в центре, двигается карта. Целиться
//  пальцем в точку, которую этот же палец и закрывает, на телефоне неудобно,
//  а на iPhone SE — тем более.
//
//  Подпись под булавкой — сначала из своего индекса адресов (без сети и
//  мгновенно), и только если там пусто — у Apple. Ни Яндекса, ни Google: чужих
//  источников в приложении нет и ради подписи не появится. Не нашлось ничего —
//  честное «Точка на карте» с координатами.
//

import CoreLocation
import MapKit
import os
import SwiftUI

struct PlacePickerMap: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let slot: PlaceSlot
    /// Место сохранено «Готово» (не «Отмена») — хозяину экрана, которому
    /// после этого есть что закрыть (поиск в режиме выбора адреса).
    var onSaved: (() -> Void)?

    /// С чего начать и что уже известно о стартовой точке.
    struct Start {
        let coordinate: CLLocationCoordinate2D
        /// Подпись сохранённого места: правим его — она и стоит под булавкой,
        /// пока карту не сдвинули.
        let title: String?

        /// Заданное место — его и правим; иначе выученное по поездкам (скорее
        /// всего, это оно и есть — остаётся нажать «Готово»); иначе где стоим;
        /// иначе центр Ташкента, как у поиска.
        init(for slot: PlaceSlot, env: AppEnvironment) {
            if let place = env.settings.place(for: slot) {
                coordinate = place.coordinate
                title = place.title
            } else if let learned = env.learnedPlaces.first(where: { $0.kind.rawValue == slot.rawValue }) {
                coordinate = learned.coordinate
                title = nil
            } else {
                coordinate = env.location.currentCoordinate ?? AppConfig.searchFallbackCenter
                title = nil
            }
        }
    }

    /// Подпись точки — вместе с точкой, для которой она найдена: карту могли
    /// сдвинуть, пока искали, и чужая подпись не должна уехать в «Мои места».
    private struct PinTitle {
        enum Source { case saved, own, apple }
        let coordinate: CLLocationCoordinate2D
        let text: String
        let source: Source
    }

    private enum Caption {
        case searching
        case found(PinTitle)
        /// Искали и не нашли — «Точка на карте».
        case nothing
    }

    @State private var position: MapCameraPosition
    /// Точка под булавкой — центр карты на последней остановке.
    @State private var center: CLLocationCoordinate2D
    /// Карта в движении: булавка приподнята, подпись ждёт остановки.
    @State private var isMoving = false
    @State private var caption: Caption
    @State private var lookupTask: Task<Void, Never>?
    /// Клетка адресов в памяти: соседние остановки карты почти всегда в ней же.
    @State private var book: AddressBook?
    @State private var bookKey: String?
    /// Один геокодер на экран: CLGeocoder не любит параллельные запросы, и
    /// прежний запрос снимается, как только карту сдвинули снова.
    @State private var geocoder = CLGeocoder()

    /// Диаметр головки булавки и длина её ножки, пт.
    private static let pinHead: CGFloat = 44
    private static let pinStem: CGFloat = 14
    /// На сколько булавка приподнимается, пока карту тянут.
    private static let pinLift: CGFloat = 10

    init(slot: PlaceSlot, start: Start, onSaved: (() -> Void)? = nil) {
        self.slot = slot
        self.onSaved = onSaved
        _position = State(initialValue: .region(MKCoordinateRegion(
            center: start.coordinate,
            latitudinalMeters: AppConfig.placePickerSpanMeters,
            longitudinalMeters: AppConfig.placePickerSpanMeters)))
        _center = State(initialValue: start.coordinate)
        _caption = State(initialValue: start.title.map {
            Caption.found(PinTitle(coordinate: start.coordinate, text: $0, source: .saved))
        } ?? .searching)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Булавка — в той же стопке, что и карта: её остриё обязано
                // совпадать с центром именно карты, а не экрана с панелью.
                ZStack {
                    map
                    pin
                }
                panel
            }
            .background(Theme.surface.ignoresSafeArea())
            .navigationTitle(Text(String(format: String(localized: "%@ на карте"), slot.name)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
        .onAppear {
            env.usage.noteScreen("placePicker")
            if case .searching = caption { scheduleLookup(delay: 0) }
        }
        .onDisappear {
            lookupTask?.cancel()
            geocoder.cancelGeocode()
        }
    }

    // MARK: - Карта и булавка

    private var map: some View {
        Map(position: $position) {
            UserAnnotation()
        }
        .mapStyle(.standard(elevation: .flat))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .onMapCameraChange(frequency: .continuous) { _ in
            if !isMoving { isMoving = true }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            isMoving = false
            let point = context.region.center
            // Карта отдаёт остановку и на первой раскладке — с той же точкой.
            // Подпись для неё уже есть (или ищется), второй запрос не нужен.
            if GeoMath.fastDistance(point.latitude, point.longitude,
                                    center.latitude, center.longitude) < 1 { return }
            center = point
            scheduleLookup(delay: AppConfig.placePickerLookupDelay)
        }
    }

    private var pin: some View {
        ZStack {
            // Тень на земле остаётся в центре и тогда, когда булавку подняли:
            // видно, куда она опустится.
            Ellipse()
                .fill(.black.opacity(0.25))
                .frame(width: 12, height: 5)
            VStack(spacing: 0) {
                Image(systemName: slot.symbol)
                    .font(.rounded(17, .bold))
                    .foregroundStyle(Theme.onAccentFill)
                    .frame(width: Self.pinHead, height: Self.pinHead)
                    .background(Theme.accentFill.gradient, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.onAccentFill, lineWidth: 2))
                Rectangle()
                    .fill(Theme.accentFill)
                    .frame(width: 3, height: Self.pinStem)
            }
            .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            // Остриё — ровно в центре карты: фигура поднята на полувысоту.
            .offset(y: -(Self.pinHead + Self.pinStem) / 2 - (isMoving ? Self.pinLift : 0))
        }
        .motionAnimation(.spring(duration: 0.25), value: isMoving)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Панель

    private var panel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.rounded(15, .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36)
                    .background(Theme.accent.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(titleText)
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    if let subtitle = subtitleText {
                        Text(subtitle)
                            .font(.rounded(12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isBusy {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(minHeight: Theme.controlSize)
            .accessibilityElement(children: .combine)

            PrimaryButton(title: "Готово", systemImage: "checkmark") { confirm() }
        }
        .padding(16)
    }

    private var isBusy: Bool {
        if isMoving { return true }
        if case .searching = caption { return true }
        return false
    }

    private var titleText: String {
        if isBusy { return String(localized: "Ищу адрес…") }
        if case .found(let found) = caption { return found.text }
        return String(localized: "Точка на карте")
    }

    /// Откуда подпись — честно: свой индекс работает без сети, Apple — нет, а
    /// у точки без адреса остаются координаты.
    private var subtitleText: String? {
        if isBusy { return nil }
        guard case .found(let found) = caption else { return Self.coordinateText(center) }
        switch found.source {
        case .own:   return String(localized: "Из своей карты · без сети")
        case .apple: return String(localized: "По данным Apple")
        case .saved: return Self.coordinateText(found.coordinate)
        }
    }

    private static func coordinateText(_ point: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", point.latitude, point.longitude)
    }

    // MARK: - Подпись под булавкой

    private func scheduleLookup(delay: Double) {
        lookupTask?.cancel()
        geocoder.cancelGeocode()
        let point = center
        caption = .searching
        lookupTask = Task {
            if delay > 0 {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return   // карту сдвинули снова — искать надо уже другую точку
                }
            }
            let found = await resolve(point)
            guard !Task.isCancelled else { return }
            caption = found.map(Caption.found) ?? .nothing
        }
    }

    private func resolve(_ point: CLLocationCoordinate2D) async -> PinTitle? {
        let key = AddressBook.key(for: point)
        if key != bookKey {
            // Ключ — после загрузки: снятая на полпути задача всё равно
            // кладёт клетку в память, и следующая остановка её не грузит.
            book = await env.roads.addressBook(for: point)
            bookKey = key
        }
        if let own = ownTitle(at: point) {
            return PinTitle(coordinate: point, text: own, source: .own)
        }
        guard env.network.isOnline, !Task.isCancelled else { return nil }
        do {
            let marks = try await geocoder.reverseGeocodeLocation(
                CLLocation(latitude: point.latitude, longitude: point.longitude))
            guard let mark = marks.first else { return nil }
            let name = mark.name ?? [mark.thoroughfare, mark.subThoroughfare]
                .compactMap(\.self).joined(separator: ", ")
            return name.isEmpty ? nil : PinTitle(coordinate: point, text: name, source: .apple)
        } catch {
            // Отмена (карту сдвинули), нет ответа, лимит геокодера — под
            // булавкой останется «Точка на карте»: точка от этого не хуже.
            Log.app.debug("геокодер булавки: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Дом из своего индекса — названием на языке приложения, как в поиске.
    private func ownTitle(at point: CLLocationCoordinate2D) -> String? {
        guard let address = book?.nearest(to: point, within: AppConfig.placePickerAddressMeters)
        else { return nil }
        let street = StreetName.display(address.street, language: env.settings.appLanguage.mapCode)
        return address.house.isEmpty ? street : "\(street), \(address.house)"
    }

    // MARK: - Готово

    private func confirm() {
        let point = center
        let title: String
        if case .found(let found) = caption,
           GeoMath.fastDistance(found.coordinate.latitude, found.coordinate.longitude,
                                point.latitude, point.longitude) < 1 {
            title = found.text
        } else {
            // Нажали, пока подпись ещё искалась: свой индекс отвечает
            // мгновенно, Apple ждать не будем — координаты честнее паузы.
            title = ownTitle(at: point) ?? Self.coordinateText(point)
        }
        env.settings.setPlace(SavedPlace(title: title, lat: point.latitude, lon: point.longitude),
                              for: slot)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onSaved?()
        dismiss()
    }
}
