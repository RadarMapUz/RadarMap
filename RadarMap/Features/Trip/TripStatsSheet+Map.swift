//
//  TripStatsSheet+Map.swift
//  RadarMap
//
//  Итоги: карта периода — превью, тепловые линии, подписи, переход на полную карту.
//

import SwiftUI
import Charts
import MapKit
import CoreLocation

extension TripStatsSheet {

    // MARK: - Карта проездов (превью → полноэкранная)

    /// Карта живёт в двух состояниях. «Все поездки»: треки склеены в слой частоты —
    /// постоянный коридор яркий и толстый, разовая поездка едва видна, поэтому
    /// вместо паутины читается личная карта дорог. «Одна поездка» (тап по строке
    /// списка): её трек в полную яркость со стартом и финишем, остальные — призраки,
    /// камеры — только этого проезда.
    @ViewBuilder var mapCard: some View {
        if !mapData.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    openMap(focus: nil)
                } label: {
                    mapPreview
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(Text(mapSelection == nil
                                         ? "Карта проездов за период. Открыть на весь экран"
                                         : "Карта выбранной поездки. Открыть на весь экран"))
                mapFooter
                    .padding(.horizontal, 4)
            }
        }
    }

    var mapPreview: some View {
        // Картинка, а не живая карта: жестов у превью нет (весь блок — кнопка
        // «открыть на весь экран»), а живая карта с сотней SwiftUI-точек
        // стоила при прокрутке как полноценная карта (см. MapPicture).
        MapPictureView(key: "period|\(mapStamp)|\(mapSelection?.id ?? 0)",
                       picture: mapPicture, height: 190)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if let selected = mapSelection { tripChip(selected).padding(10) }
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
    }

    /// Две картины одной карты. «Все поездки»: слой частоты — постоянный
    /// коридор яркий и толстый, разовая поездка едва видна. «Одна поездка»:
    /// её трек в полную яркость со стартом и финишем, остальные — призраки.
    /// Камеры: чистые — маленькие зелёные, с превышением — крупнее, красные
    /// и поверх: сотня одинаковых кругов читалась пятном, а не картой.
    var mapPicture: MapPicture {
        var picture = MapPicture()
        func coordinates(_ track: [TrackPoint]) -> [CLLocationCoordinate2D] {
            track.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        }
        if let selected = mapSelection {
            for track in mapData.tracks {
                picture.lines.append(.init(coordinates: coordinates(track),
                                           color: Theme.route.opacity(0.18), width: 2))
            }
            let points = selected.trackPoints
            picture.lines.append(.init(coordinates: coordinates(points), color: Theme.route,
                                       width: 4, casing: Theme.routeCasing, casingWidth: 7))
            picture.dots += markerDots(TripHistory.passMarkers(of: selected))
            if let start = points.first, let finish = points.last {
                picture.dots += TripEndpoints.dots(
                    start: CLLocationCoordinate2D(latitude: start.lat, longitude: start.lon),
                    finish: CLLocationCoordinate2D(latitude: finish.lat, longitude: finish.lon))
            }
        } else {
            // Сначала все каймы, потом все линии: кайма следующей линии не
            // должна перечёркивать предыдущую.
            for line in mapData.heat where line.tier > 0 {
                picture.lines.append(.init(coordinates: line.coordinates,
                                           color: Theme.routeCasing.opacity(0.8),
                                           width: Self.heatWidth(line.tier) + 3))
            }
            for line in mapData.heat {
                picture.lines.append(.init(coordinates: line.coordinates,
                                           color: Theme.route.opacity(Self.heatOpacity(line.tier)),
                                           width: Self.heatWidth(line.tier)))
            }
            picture.dots += markerDots(mapData.markers)
        }
        return picture
    }

    func markerDots(_ markers: [PassMarker]) -> [MapPicture.Dot] {
        let clean = markers.filter { !$0.hasViolation }
        let over = markers.filter(\.hasViolation)
        let cleanSize: CGFloat = markers.count > 60 ? 6 : 8
        // Цвет — тот же, что на полной карте: лимит неизвестен — серая точка.
        return clean.map {
            MapPicture.Dot(coordinate: $0.coordinate, diameter: cleanSize,
                           fill: PeriodMapSheet.tint($0), ringWidth: 1.2)
        } + over.map {
            MapPicture.Dot(coordinate: $0.coordinate, diameter: 13, fill: Theme.danger, ringWidth: 2)
        }
    }

    static func heatWidth(_ tier: Int) -> CGFloat {
        switch tier {
        case 2:  return 5
        case 1:  return 3.5
        default: return 2
        }
    }

    static func heatOpacity(_ tier: Int) -> Double {
        switch tier {
        case 2:  return 1
        case 1:  return 0.7
        default: return 0.35
        }
    }

    /// Подпись выбранной поездки поверх карты — не занимает строку под ней.
    func tripChip(_ record: TripRecord) -> some View {
        HStack(spacing: 8) {
            Text(Formatting.clock(record.startedAt))
                .font(.rounded(15, .bold))
                .foregroundStyle(Theme.textPrimary)
            Text(Formatting.distance(record.distanceMeters))
                .font(.rounded(15, .medium))
                .foregroundStyle(Theme.textSecondary)
            if let score = record.score {
                Text("\(Int(score))")
                    .font(.rounded(15, .heavy).monospacedDigit())
                    .foregroundStyle(TripHistorySection.scoreColor(Int(score)))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.background.opacity(0.8), in: Capsule())
        .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
    }

    // MARK: - Подпись под картой

    /// Без выбора — легенда цветов и вход в полный экран. С выбором — возврат
    /// ко всем поездкам и вход в деталку: тап по строке теперь занят картой.
    @ViewBuilder var mapFooter: some View {
        if let selected = mapSelection {
            HStack(spacing: 10) {
                Button {
                    withMotion(Motion.standard) { clearMapSelection() }
                } label: {
                    // 11 pt подписи — это ~15 pt в высоту; мишень дотягиваем
                    // до 44 внутри label, иначе область касания не растёт.
                    Label("Все поездки", systemImage: "xmark.circle.fill")
                        .font(.rounded(11, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .tapTarget()
                }
                .buttonStyle(PressableStyle())
                Spacer(minLength: 0)
                Button {
                    selectedRecord = selected
                } label: {
                    HStack(spacing: 4) {
                        Text("Подробнее")
                            .font(.rounded(11, .semibold))
                        Image(systemName: "chevron.right")
                            .font(.rounded(9, .bold))
                    }
                    .foregroundStyle(Theme.accent)
                    .tapTarget()
                }
                .buttonStyle(PressableStyle())
            }
        } else {
            // Легенда объясняет цвета, а не считает: точки — это РАЗНЫЕ камеры,
            // и их число рядом с «проездами камер» карточки денег читалось
            // третьим счётчиком с похожим словом (6.2). Не помещается в строку
            // с «Открыть» (узбекский, крупный шрифт) — встаёт над ней.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    legendKeys
                    Spacer(minLength: 0)
                    openMapButton
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 14) { legendKeys }
                    openMapButton
                }
            }
        }
    }

    /// Ключи цвета — только тех точек, что есть на карте. Пустая легенда —
    /// честное «камер по пути не было», а не зелёный ноль.
    @ViewBuilder var legendKeys: some View {
        let markers = mapData.markers
        if markers.isEmpty {
            Text("Камер по пути не было")
                .font(.rounded(11))
                .foregroundStyle(Theme.textTertiary)
        }
        if markers.contains(where: { !$0.hasViolation && !$0.limitUnknown }) {
            legendItem(Theme.success, String(localized: "в лимите"))
        }
        if markers.contains(where: \.hasViolation) {
            legendItem(Theme.danger, String(localized: "с превышением"))
        }
        if markers.contains(where: { !$0.hasViolation && $0.limitUnknown }) {
            legendItem(Theme.textTertiary, String(localized: "лимит неизвестен"))
        }
    }

    var openMapButton: some View {
        Button {
            openMap(focus: nil)
        } label: {
            HStack(spacing: 4) {
                Text("Открыть")
                    .font(.rounded(11, .semibold))
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.rounded(9, .bold))
            }
            .foregroundStyle(Theme.accent)
            .tapTarget()
        }
        .buttonStyle(PressableStyle())
    }

    func legendItem(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.rounded(11)).foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: - Выбор поездки и переходы на карту

    /// Тап по строке списка «применяет» поездку к карте: экран сам подкручивается
    /// к карте (иначе изменение произошло бы за кадром), камера едет к треку.
    func showOnMap(_ record: TripRecord, proxy: ScrollViewProxy) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let same = mapSelection?.id == record.id
        withMotion(Motion.standard) {
            if same {
                clearMapSelection()
            } else {
                mapSelection = record
            }
            proxy.scrollTo("map", anchor: .top)
        }
    }

    func clearMapSelection() {
        mapSelection = nil
    }

    func openMap(focus: PassMarker?) {
        // Полноэкранная карта уважает выбор: показывает то же, что и превью.
        let data = mapSelection.map { TripHistory.mapData(of: $0) } ?? mapData
        mapPayload = PeriodMapPayload(data: data, focus: focus)
    }
}
