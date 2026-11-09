import SwiftUI
import WidgetKit

@MainActor func stats(_ f: WidgetFamily, _ size: CGSize, _ s: ColorScheme, _ snapshot: Snap, _ label: String = "", at: Date = thu1830) -> Shot {
    home(f, size, s, label) { RadarStatsView(entry: RadarStatsEntry(date: at, snapshot: snapshot)) }
}
@MainActor func comm(_ f: WidgetFamily, _ size: CGSize, _ s: ColorScheme, _ data: CommuteWidgetData?, _ at: Date, _ label: String = "") -> Shot {
    home(f, size, s, label) { RadarCommuteView(entry: RadarCommuteEntry(date: at, data: data)) }
}

@MainActor func nowSheets() {
    let cases: [(String, Snap)] = [("full", snapFull), ("few", snapFew), ("empty", snapEmpty), ("noAccess", snapNoAccess), ("новая неделя, нет поездок", snapNewWeek), ("снимок прошлой недели", snapLastWeek)]
    for (schemeName, s) in [("light", ColorScheme.light), ("dark", .dark)] {
        var rows: [Row] = []
        for (n, sn) in cases {
            rows.append(Row(title: n, shots: [stats(.systemSmall, Size.small, s, sn), stats(.systemMedium, Size.medium, s, sn), stats(.systemLarge, Size.large, s, sn)]))
        }
        sheet("now_stats_\(schemeName)_\(LANG)", "RadarStatsWidget: сейчас (\(schemeName), \(LANG)), экран 390", rows)
    }
    // Сколько контенту нужно высоты на большом размере: без ограничения по высоте.
    for (n, w) in [("390", CGFloat(306)), ("SE", CGFloat(289)), ("430", CGFloat(332))] {
        StandEnv.family = .systemLarge
        let m = snap(RadarStatsView(entry: RadarStatsEntry(date: thu1830, snapshot: snapFull)).frame(width: w).fixedSize(horizontal: false, vertical: true).environment(\.colorScheme, .light))
        print("большой full, ширина контента", n, w, "нужно высоты", m.h)
    }
    // Малый экран
    var se: [Row] = []
    for (n, sn) in [("full", snapFull), ("few", snapFew), ("empty", snapEmpty)] {
        se.append(Row(title: n, shots: [stats(.systemSmall, Size.smallSE, .light, sn), stats(.systemMedium, Size.mediumSE, .light, sn), stats(.systemLarge, Size.largeSE, .dark, sn)]))
    }
    sheet("now_stats_se_\(LANG)", "RadarStatsWidget: iPhone SE (148 / 321×148 / 321×324), \(LANG)", se)

    // Дорога
    let cm: [(String, CommuteWidgetData?, Date)] = [
        ("утро: окно «сейчас» и пробки", commute(thu0805, slot: true, jam: true), thu0805),
        ("утро: только норма и совет", commute(thu0805, slot: false, jam: false), thu0805),
        ("вечер: домой", commute(thu1830, slot: true, jam: true), thu1830),
        ("нет данных", nil, thu0805)]
    var cr: [Row] = []
    for (n, d, t) in cm {
        cr.append(Row(title: n, shots: [comm(.systemSmall, Size.small, .light, d, t), comm(.systemMedium, Size.medium, .light, d, t),
                                        comm(.systemSmall, Size.smallSE, .dark, d, t), comm(.systemMedium, Size.mediumSE, .dark, d, t)]))
    }
    sheet("now_commute_\(LANG)", "RadarCommuteWidget: сейчас, \(LANG)", cr)

    // Локскрин
    var lk: [Row] = []
    for (n, sn) in cases {
        let entry = RadarWeekEntry(date: thu1830, snapshot: sn)
        lk.append(Row(title: "RadarWeekWidget — \(n)", shots: [
            lock(.accessoryCircular, Size.circular) { RadarWeekView(entry: entry) },
            lock(.accessoryRectangular, Size.rectangular) { RadarWeekView(entry: entry) },
            lock(.accessoryInline, Size.inline) { RadarWeekView(entry: entry) }]))
    }
    let e = RadarStatsEntry(date: thu1830, snapshot: snapFull)
    lk.append(Row(title: "RadarStatsWidget на локскрине (кнопка старта)", shots: [
        lock(.accessoryCircular, Size.circular) { RadarStatsView(entry: e) },
        lock(.accessoryRectangular, Size.rectangular) { RadarStatsView(entry: e) }]))
    for (n, d, t) in cm {
        let c = RadarCommuteEntry(date: t, data: d)
        lk.append(Row(title: "RadarCommuteWidget — \(n)", shots: [
            lock(.accessoryRectangular, Size.rectangular) { RadarCommuteView(entry: c) },
            lock(.accessoryInline, Size.inline) { RadarCommuteView(entry: c) }]))
    }
    sheet("now_lock_\(LANG)", "Экран блокировки: сейчас, \(LANG)", lk, note: "Один цвет поверх обоев — приближение системного режима.")

    // Live Activity
    let states: [(String, AS, Bool)] = [("камера далеко, прибытие", cameraFar, false), ("камера близко, уровень 3", cameraNear, false), ("отмечено", cameraFlash, false), ("окно отмены", cameraUndo, false), ("не отправлено, звук выкл.", cameraFail, false), ("камер нет", noCamera, false), ("нет сигнала", cameraFar, true)]
    var la: [Row] = []
    for (n, st, stale) in states {
        StandEnv.activityFamily = .medium
        let screen = snap(ActivityContent(state: st, isStale: stale).frame(width: 370).background(WTheme.background.opacity(0.92)).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous)).background(Wallpaper().clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))).environment(\.colorScheme, .dark))
        StandEnv.activityFamily = .small
        let small = snap(ActivityContent(state: st, isStale: stale).frame(width: 170, height: 72).background(WTheme.background).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)).environment(\.colorScheme, .dark))
        let w = CameraActivityWidget()
        let compact = snap(HStack { w.typeIcon(st, isStale: stale); Spacer(); if !stale, let d = st.distanceMeters { Text(format(d)).font(.system(.caption2).bold()).foregroundStyle(WTheme.level(st.alertLevel)) } }
            .padding(.horizontal, 14).frame(width: 220, height: 37).background(Capsule().fill(.black)).environment(\.colorScheme, .dark))
        let expanded = snap(VStack(spacing: 6) {
            HStack { w.typeIcon(st, isStale: stale); Spacer(); if !stale, let d = st.distanceMeters { Text(format(d)).font(.system(.title3, design: .rounded).bold()).foregroundStyle(WTheme.level(st.alertLevel)) } }
            VStack(alignment: .leading, spacing: 4) {
                if !stale { ApproachBar(state: st) }
                Group { if stale { Text("Нет сигнала GPS") } else if let t = st.nearestTitle { Text(t) } else { Text("Камер рядом нет") } }.font(.system(.footnote)).foregroundStyle(WTheme.secondary).lineLimit(stale ? 2 : 1)
                if !stale { GhostLine(state: st); ActivityButtons(state: st, height: 34).padding(.top, 2) }
            }
        }.padding(16).frame(width: 370).background(RoundedRectangle(cornerRadius: 40, style: .continuous).fill(.black)).environment(\.colorScheme, .dark))
        la.append(Row(title: n, shots: [screen, small, compact, expanded]))
    }
    sheet("now_activity_\(LANG)", "Live Activity: локскрин, малое лицо, остров сжатый (собран вручную), остров развёрнутый (собран вручную), \(LANG)", la, ground: Color(white: 0.75))

    // Часы
    func w(_ s: WatchComplicationSnapshot?, _ stale: Bool) -> NextCameraEntry { NextCameraEntry(date: thu1830, snapshot: s, isStale: stale) }
    let ws: [(String, NextCameraEntry)] = [("камера", w(.sample, false)), ("устарело", w(.sample, true)),
        ("камер нет", w(.init(state: .init(isTripActive: true, camera: nil), updatedAt: thu1830), false)),
        ("нет поездки", w(.init(state: .noTrip, updatedAt: thu1830), false))]
    var wr: [Row] = []
    for (n, entry) in ws {
        wr.append(Row(title: n, shots: [
            lock(.accessoryCircular, CGSize(width: 50, height: 50), mono: false) { NextCameraView(entry: entry).environment(\.colorScheme, .dark) },
            lock(.accessoryRectangular, CGSize(width: 170, height: 54), mono: false) { NextCameraView(entry: entry).environment(\.colorScheme, .dark) },
            lock(.accessoryInline, CGSize(width: 170, height: 22), mono: false) { NextCameraView(entry: entry).environment(\.colorScheme, .dark) }]))
    }
    sheet("now_watch_\(LANG)", "Часы: компликация «Следующая камера», \(LANG)", wr)

    // Тонированный и прозрачный — эмуляция
    func t(_ f: WidgetFamily, _ size: CGSize, _ v: Snap) -> Shot { bare(f, size) { RadarStatsView(entry: RadarStatsEntry(date: thu1830, snapshot: v)) } }
    func c(_ f: WidgetFamily, _ size: CGSize, _ d: CommuteWidgetData?, _ at: Date) -> Shot { bare(f, size) { RadarCommuteView(entry: RadarCommuteEntry(date: at, data: d)) } }
    let tint = Color(red: 1, green: 0.78, blue: 0.45)
    sheet("now_tinted_\(LANG)", "Тонированный и «Прозрачный» iOS 26 — эмуляция (цвет снят, остаётся альфа), \(LANG)", [
        Row(title: "Тонированный", shots: [accented(t(.systemSmall, Size.small, snapFull), tint: tint, glass: false, "full"), accented(t(.systemMedium, Size.medium, snapFull), tint: tint, glass: false, "full"), accented(t(.systemSmall, Size.small, snapEmpty), tint: tint, glass: false, "empty: значок на заливке")]),
        Row(title: "Прозрачный", shots: [accented(t(.systemSmall, Size.small, snapFull), tint: .white, glass: true, "full"), accented(t(.systemLarge, Size.large, snapFull), tint: .white, glass: true, "large: красный день и риск без цвета"), accented(c(.systemSmall, Size.small, commute(thu0805, slot: true, jam: true), thu0805), tint: .white, glass: true, "дорога")]),
    ], note: "Приближение: система снимает цвета и строит из альфы. Проверить на телефоне перед работой.")
}

MainActor.assumeIsolated {
    try? FileManager.default.createDirectory(atPath: OUT, withIntermediateDirectories: true)
    if CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "mock" {
        mockSheets()
    } else {
        nowSheets()
    }
    print("готово")
}
