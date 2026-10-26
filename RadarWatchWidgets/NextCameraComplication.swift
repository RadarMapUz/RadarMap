//
//  NextCameraComplication.swift
//  RadarWatchWidgets
//
//  Компликация «следующая камера» (план 19.10, 9.3б): значок типа на диске
//  цвета типа — как маркер на карте — и верхняя граница дистанции («< 1 км»).
//  Вне поездки — «нет поездки», в поездке без камеры — «камер рядом нет».
//
//  Расширение ничего не считает и ни о чём не спрашивает телефон: снимок
//  кладёт приложение часов (ComplicationFeed), оно же решает, когда тратить
//  перезагрузку. Здесь — только показ и одна честность: снимок поездки
//  старше 10 минут рисуется приглушённо и со временем «данные на 12:04» —
//  часы не знают, стоим ли мы на светофоре или телефон разрядился.
//

import SwiftUI
import WidgetKit
import os

struct NextCameraEntry: TimelineEntry {
    let date: Date
    /// nil — снимка нет (приложение часов ещё не получало контекст).
    let snapshot: WatchComplicationSnapshot?
    let isStale: Bool
}

struct NextCameraProvider: TimelineProvider {
    private static let log = Logger(subsystem: "uz.radarmap.ios.watch.widgets", category: "complication")

    func placeholder(in context: Context) -> NextCameraEntry {
        NextCameraEntry(date: Date(), snapshot: .sample, isStale: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (NextCameraEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        let snapshot = Self.load()
        let now = Date()
        completion(NextCameraEntry(date: now, snapshot: snapshot,
                                   isStale: snapshot.map { WatchComplication.isStale($0, now: now) } ?? false))
    }

    /// Таймлайн без перезагрузок по расписанию: свежее приносит приложение
    /// часов, а переход в «устарело» — вторая запись того же таймлайна.
    func getTimeline(in context: Context, completion: @escaping (Timeline<NextCameraEntry>) -> Void) {
        let snapshot = Self.load()
        let now = Date()
        let dates = snapshot.map { WatchComplication.entryDates(for: $0, now: now) } ?? [now]
        let entries = dates.map { date in
            NextCameraEntry(date: date, snapshot: snapshot,
                            isStale: snapshot.map { WatchComplication.isStale($0, now: date) } ?? false)
        }
        completion(Timeline(entries: entries, policy: .never))
    }

    private static func load() -> WatchComplicationSnapshot? {
        guard let data = SharedDefaults.store?.data(forKey: WatchComplication.snapshotKey) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(WatchComplicationSnapshot.self, from: data)
        } catch {
            log.error("снимок компликации не прочитан: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

struct NextCameraComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WatchComplication.kind, provider: NextCameraProvider()) { entry in
            NextCameraView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName(String(localized: "Следующая камера"))
        .description(String(localized: "Камера впереди и расстояние до неё во время поездки."))
        .supportedFamilies([.accessoryCircular, .accessoryRectangular,
                            .accessoryCorner, .accessoryInline])
    }
}

// MARK: - Вид

private enum Look {
    static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }
    static let accent = color(WidgetPalette.accentFill.dark)
    static let success = color(WidgetPalette.successFill.dark)
    static let secondary = color(WidgetPalette.secondary.dark)
}

/// Что на циферблате — одно из трёх.
private enum Face {
    case noTrip
    case clear
    case camera(WatchComplicationState.Camera)

    init(_ snapshot: WatchComplicationSnapshot?) {
        guard let state = snapshot?.state, state.isTripActive else { self = .noTrip; return }
        self = state.camera.map { .camera($0) } ?? .clear
    }

    var symbol: String {
        switch self {
        case .noTrip: return "car.fill"
        case .clear: return "checkmark.shield.fill"
        case .camera(let camera): return camera.symbol
        }
    }

    /// Заливка диска: камера — цвет типа, «нет камер» — зелёный, нет
    /// поездки — синий интерфейса. Красный — только у камеры.
    var fill: Color {
        switch self {
        case .noTrip: return Look.accent
        case .clear: return Look.success
        case .camera(let camera): return Look.color(WidgetPalette.cameraFill(symbol: camera.symbol))
        }
    }

    var glyph: Color {
        switch self {
        case .camera(let camera): return Look.color(WidgetPalette.cameraGlyph(symbol: camera.symbol))
        default: return .white
        }
    }

    /// Главная строка: дистанция или состояние.
    var headline: String {
        switch self {
        case .noTrip: return String(localized: "Нет поездки")
        case .clear: return String(localized: "Камер рядом нет")
        case .camera(let camera): return WatchComplication.distanceText(within: camera.within)
        }
    }
}

struct NextCameraView: View {
    let entry: NextCameraEntry
    @Environment(\.widgetFamily) private var family

    private var face: Face { Face(entry.snapshot) }

    /// «данные на 12:04» — только у устаревшего снимка поездки.
    private var staleText: String? {
        guard entry.isStale, let updatedAt = entry.snapshot?.updatedAt else { return nil }
        let time = updatedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened)
            .locale(NumberFormat.locale))
        return String(format: String(localized: "данные на %@"), time)
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: circular
            case .accessoryCorner: corner
            case .accessoryInline: inline
            default: rectangular
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    /// Камера — её глиф (29.C, тот же, что на карте телефона), остальное — символ.
    @ViewBuilder
    private func symbol(size: CGFloat, color: Color) -> some View {
        if case .camera(let camera) = face, let glyph = CameraGlyph(symbol: camera.symbol) {
            CameraGlyphView(glyph: glyph, ink: color, side: (size * 1.25).rounded())
        } else {
            Image(systemName: face.symbol)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(color)
        }
    }

    private var disc: some View {
        symbol(size: 11, color: face.glyph)
            .frame(width: 22, height: 22)
            .background(Circle().fill(face.fill).widgetAccentable())
            .opacity(entry.isStale ? 0.45 : 1)
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if case .camera(let camera) = face {
                VStack(spacing: 1) {
                    disc
                    Text(WatchComplication.distanceText(within: camera.within))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .foregroundStyle(entry.isStale ? Look.secondary : .white)
                }
                .padding(.horizontal, 3)
            } else {
                Image(systemName: face.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(face.fill)
                    .widgetAccentable()
            }
        }
    }

    private var corner: some View {
        symbol(size: 20, color: face.fill)
            .widgetAccentable()
            .opacity(entry.isStale ? 0.45 : 1)
            .widgetLabel {
                Text(face.headline)
            }
    }

    private var inline: some View {
        // Инлайн — одна строка текста и один значок; цвет система всё равно снимет.
        Label {
            Text(staleText.map { String(format: String(localized: "%1$@ · %2$@"), face.headline, $0) }
                 ?? face.headline)
        } icon: {
            Image(systemName: face.symbol)
        }
    }

    private var rectangular: some View {
        HStack(spacing: 8) {
            symbol(size: 15, color: face.glyph)
                .frame(width: 32, height: 32)
                .background(Circle().fill(face.fill).widgetAccentable())
                .opacity(entry.isStale ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 0) {
                Text(face.headline)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(entry.isStale ? Look.secondary : .white)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Look.secondary)
                        .lineLimit(1)
                }
                if let staleText {
                    Text(staleText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Look.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var subtitle: String? {
        switch face {
        case .camera(let camera): return camera.title ?? String(localized: "до камеры")
        case .noTrip, .clear: return nil
        }
    }

    private var accessibilityText: String {
        switch face {
        case .camera(let camera):
            let parts = [WatchComplication.distanceText(within: camera.within),
                         camera.title ?? String(localized: "до камеры"), staleText].compactMap { $0 }
            return parts.joined(separator: ", ")
        case .noTrip, .clear:
            return [face.headline, staleText].compactMap { $0 }.joined(separator: ", ")
        }
    }
}

extension WatchComplicationSnapshot {
    /// Образец для галереи циферблатов и превью.
    static let sample = WatchComplicationSnapshot(
        state: WatchComplicationState(isTripActive: true,
                                      camera: .init(symbol: "camera.fill", title: "Амир Темур", within: 500)),
        updatedAt: Date())
}

#Preview("Прямоугольная", as: .accessoryRectangular) {
    NextCameraComplication()
} timeline: {
    NextCameraEntry(date: .now, snapshot: .sample, isStale: false)
    NextCameraEntry(date: .now, snapshot: .sample, isStale: true)
    NextCameraEntry(date: .now, snapshot: nil, isStale: false)
}

#Preview("Круглая", as: .accessoryCircular) {
    NextCameraComplication()
} timeline: {
    NextCameraEntry(date: .now, snapshot: .sample, isStale: false)
}
