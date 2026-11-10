import SwiftUI
import WidgetKit
import ImageIO
import UniformTypeIdentifiers

enum StandEnv {
    nonisolated(unsafe) static var family: WidgetFamily = .systemSmall
    nonisolated(unsafe) static var activityFamily: ActivityFamily = .medium
}

let OUT = CommandLine.arguments[1]
let LANG = CommandLine.arguments[2]
let Scale: CGFloat = 3

/// Настоящий виджет снимается в картинку сразу: семейство — общая переменная.
struct Shot { let image: CGImage; let label: String; var w: CGFloat { CGFloat(image.width) / Scale } ; var h: CGFloat { CGFloat(image.height) / Scale } }

@MainActor func snap<V: View>(_ v: V, _ label: String = "") -> Shot {
    let r = ImageRenderer(content: v)
    r.scale = Scale
    r.isOpaque = false
    guard let i = r.cgImage else { fatalError("пусто \(label)") }
    return Shot(image: i, label: label)
}

enum Size {
    static let small = CGSize(width: 158, height: 158)
    static let medium = CGSize(width: 338, height: 158)
    static let large = CGSize(width: 338, height: 354)
    static let smallSE = CGSize(width: 148, height: 148)
    static let mediumSE = CGSize(width: 321, height: 148)
    static let largeSE = CGSize(width: 321, height: 324)
    static let circular = CGSize(width: 72, height: 72)
    static let rectangular = CGSize(width: 160, height: 72)
    static let inline = CGSize(width: 234, height: 26)
}

/// Карточка системы: поля 16, скругление 22, фон из containerBackground.
@MainActor func home<V: View>(_ f: WidgetFamily, _ size: CGSize, _ s: ColorScheme, _ label: String = "", _ v: () -> V) -> Shot {
    StandEnv.family = f
    let content = v()
        .padding(16)
        .frame(width: size.width, height: size.height)
        .background(SW.background)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, s)
    return snap(content, label)
}

/// Содержимое виджета без фона — для эмуляции тонированного режима.
@MainActor func bare<V: View>(_ f: WidgetFamily, _ size: CGSize, _ v: () -> V) -> Shot {
    StandEnv.family = f
    let content = v().padding(16).frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)
    return snap(content)
}

struct Wallpaper: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.13, green: 0.20, blue: 0.42), Color(red: 0.42, green: 0.22, blue: 0.40), Color(red: 0.75, green: 0.42, blue: 0.28)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Эмуляция тонированного/прозрачного режима: у системы цвет отбрасывается,
/// остаётся альфа. Это приближение, а не снимок системы.
@MainActor func accented(_ shot: Shot, tint: Color, glass: Bool, _ label: String = "") -> Shot {
    let v = ZStack {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(glass ? Color.white.opacity(0.16) : Color.black.opacity(0.55))
        Image(decorative: shot.image, scale: Scale).renderingMode(.template).foregroundStyle(tint)
    }
    .frame(width: shot.w, height: shot.h)
    .padding(8)
    .background(Wallpaper())
    return snap(v, label)
}

/// Локскрин: один цвет поверх обоев.
@MainActor func lock<V: View>(_ f: WidgetFamily, _ size: CGSize, _ label: String = "", mono: Bool = true, _ v: () -> V) -> Shot {
    StandEnv.family = f
    let raw = snap(v().frame(width: size.width, height: size.height)
        .foregroundStyle(.white).environment(\.colorScheme, .dark))
    let body = Group {
        if mono { Image(decorative: raw.image, scale: Scale).renderingMode(.template).foregroundStyle(.white.opacity(0.92)) }
        else { Image(decorative: raw.image, scale: Scale) }
    }
    return snap(body.padding(6).background(Wallpaper()), label)
}

@MainActor func save(_ s: Shot, _ name: String) {
    let url = URL(fileURLWithPath: OUT + "/" + name + ".png")
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, s.image, nil)
    CGImageDestinationFinalize(d)
}

struct Row { let title: String; let shots: [Shot] }

struct ShotView: View {
    let s: Shot
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(decorative: s.image, scale: Scale)
            if !s.label.isEmpty {
                Text(verbatim: s.label).font(.system(size: 11, weight: .medium)).foregroundStyle(Color(white: 0.3))
                    .frame(maxWidth: s.w, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Лист снимков. scale 2 — чтобы файлы оставались разумными.
@MainActor func sheet(_ name: String, _ title: String, _ rows: [Row], note: String? = nil, ground: Color = Color(white: 0.87)) {
    let v = VStack(alignment: .leading, spacing: 22) {
        Text(verbatim: title).font(.system(size: 22, weight: .bold)).foregroundStyle(.black)
        if let note { Text(verbatim: note).font(.system(size: 13)).foregroundStyle(Color(white: 0.25)).frame(maxWidth: 900, alignment: .leading) }
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            VStack(alignment: .leading, spacing: 8) {
                if !row.title.isEmpty { Text(verbatim: row.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.black) }
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(row.shots.enumerated()), id: \.offset) { _, s in ShotView(s: s) }
                }
            }
        }
    }
    .padding(24)
    .background(ground)
    .environment(\.colorScheme, .light)
    let r = ImageRenderer(content: v)
    r.scale = 2
    guard let i = r.cgImage else { fatalError(name) }
    let url = URL(fileURLWithPath: OUT + "/" + name + ".png")
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, i, nil)
    CGImageDestinationFinalize(d)
    print("лист", name, i.width, i.height)
}
