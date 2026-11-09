import SwiftUI
import WidgetKit
import UIKit

// Макеты новых виджетов. Цвета — Theme.Stats (плaн 59) и палитра виджетов.
func hex(_ v: UInt32) -> Color { SW.fixed(v) }
func adaptive(_ l: UInt32, _ d: UInt32) -> Color {
    Color(uiColor: UIColor { t in
        let h = t.userInterfaceStyle == .dark ? d : l
        return UIColor(red: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: 1)
    })
}
enum St {
    static let commute = adaptive(0x5B3DF5, 0x9A85FF)
    static let other = adaptive(0x0B9F78, 0x3BE3B0)
    static let ground = hex(0x0E1014)
    static let calm = [hex(0x2BF0B5), hex(0x19C8E8)]
    static let watch = [hex(0xFFD15C), hex(0xFF9A2E)]
    static let risk = [hex(0xFF5C7A), hex(0xE0218A)]
    static let road = [hex(0xB49CFF), hex(0x6C4DFF)]
    static let action = hex(0xFFD43B)
    static let onAction = hex(0x1C1C1E)
    static let quiet = adaptive(0xF2F1EE, 0x2A2A29)
}
func T(_ ru: String, _ uz: String) -> String { LANG == "uz" ? uz : ru }

struct DayM { let score: Int?; let road: Double; var fine = false; var perfect = false }
struct WeekM {
    var km: Double; var usual: Double?; var score: Int?; var risk: String?
    var days: [DayM?]; var today: Int?
}
let wFull = WeekM(km: 118, usual: 165, score: 67, risk: "≈ 2,2 млн", days: [DayM(score: 84, road: 0.9), DayM(score: 92, road: 0.55, perfect: true), DayM(score: 48, road: 1, fine: true), DayM(score: 76, road: 0.6), nil, nil, nil], today: 3)
let wClean = WeekM(km: 142, usual: 165, score: 91, risk: nil, days: [DayM(score: 94, road: 0.9, perfect: true), DayM(score: 92, road: 0.75, perfect: true), DayM(score: 86, road: 1), DayM(score: 90, road: 0.8, perfect: true), DayM(score: 95, road: 0.5, perfect: true), nil, nil], today: 4)
let wFew = WeekM(km: 22.3, usual: nil, score: 81, risk: nil, days: [nil, nil, nil, DayM(score: 81, road: 0.8), nil, nil, nil], today: 3)
let letters = LANG == "uz" ? ["D","S","C","P","J","S","Y"] : ["П","В","С","Ч","П","С","В"]

func tierColors(_ s: Int?) -> [Color] { guard let s else { return St.calm }; return s >= 75 ? St.calm : s >= 60 ? St.watch : St.risk }

struct Arc: View {
    let value: Double; let colors: [Color]; let width: CGFloat; var inset: CGFloat = 0; var mono: Color? = nil
    var body: some View {
        ZStack {
            Circle().stroke((mono ?? colors.last ?? .white).opacity(0.2), lineWidth: width)
            if value > 0 {
                Circle().trim(from: 0, to: min(1, value))
                    .stroke(mono.map { AnyShapeStyle($0) } ?? AnyShapeStyle(AngularGradient(colors: colors + [colors.first ?? .white], center: .center)),
                            style: StrokeStyle(lineWidth: width, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }.padding(width / 2 + inset)
    }
}
/// Два кольца как в календаре «Итогов»: внешнее — аккуратность, внутреннее — пробег.
struct Rings: View {
    let score: Int?; let road: Double?; let side: CGFloat
    var a: Color? = nil; var b: Color? = nil
    var body: some View {
        let w = side * 0.135
        ZStack {
            Arc(value: Double(score ?? 0) / 100, colors: tierColors(score), width: w, mono: a)
            if let road { Arc(value: road, colors: St.road, width: w, inset: w * 1.3, mono: b) }
        }.frame(width: side, height: side)
    }
}
struct DayRing: View {
    let d: DayM?; let side: CGFloat
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Rings(score: d?.score, road: d?.road ?? 0, side: side).opacity(d == nil ? 0.35 : 1)
            if let d, d.fine || d.perfect {
                Circle().fill(d.fine ? hex(0xFF7A70) : St.action).frame(width: side * 0.24, height: side * 0.24).offset(x: side * 0.06, y: -side * 0.06)
            }
        }.frame(width: side, height: side)
    }
}
func tierText(_ s: Int) -> Color { s >= 75 ? hex(0x4CC27A) : s >= 60 ? hex(0xFFB020) : hex(0xFF7A70) }

struct WeekRow: View {
    let w: WeekM; let side: CGFloat
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<7, id: \.self) { i in
                VStack(spacing: 3) {
                    DayRing(d: w.days[i], side: side)
                    Text(letters[i]).font(.system(size: 9, weight: w.today == i ? .heavy : .medium))
                        .foregroundStyle(w.today == i ? Color.white : Color.white.opacity(0.55))
                }.frame(maxWidth: .infinity)
            }
        }
    }
}
struct KmHero: View {
    let km: Double; let size: CGFloat
    var text: String { km < 100 ? String(format: "%.1f", km).replacingOccurrences(of: ".", with: ",") : "\(Int(km))" }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(text).font(.system(size: size, weight: .heavy, design: .rounded))
            Text(T("км", "km")).font(.system(size: size * 0.5, weight: .bold, design: .rounded))
        }.foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
    }
}
func usualText(_ w: WeekM) -> String {
    guard let u = w.usual else { return T("последняя — 2 часа назад", "oxirgisi — 2 soat oldin") }
    return LANG == "uz" ? "odatdagi \(Int(u)) km dan" : "из обычных \(Int(u)) км"
}
struct ScoreBadge: View {
    let score: Int; var size: CGFloat = 12
    var body: some View {
        Text(T("балл \(score)", "ball \(score)")).font(.system(size: size, weight: .heavy))
            .foregroundStyle(tierText(score)).padding(.horizontal, 7).padding(.vertical, 3)
            .background(tierText(score).opacity(0.18), in: Capsule()).fixedSize()
    }
}
struct Money: View {
    let risk: String?; var size: CGFloat = 12
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: risk == nil ? "checkmark.shield.fill" : "exclamationmark.shield.fill").font(.system(size: size - 1, weight: .bold)).foregroundStyle(risk == nil ? hex(0x4CC27A) : hex(0xFF7A70))
            Text(risk.map { $0 + T(" сум", " so‘m") } ?? T("Без штрафов", "Jarimalarsiz")).font(.system(size: size, weight: .bold, design: .rounded)).foregroundStyle(risk == nil ? Color.white : hex(0xFF7A70)).lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}

// MARK: Неделя кольцами (всегда тёмная, как календарь «Итогов»)
struct WeekSmall: View {
    let w: WeekM; var side: CGFloat = 70
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Rings(score: w.score, road: w.usual == nil ? nil : w.km / (w.usual ?? 1), side: side)
                Spacer(minLength: 2)
                if let s = w.score {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(verbatim: "\(s)").font(.system(size: 24, weight: .heavy, design: .rounded)).foregroundStyle(tierText(s))
                        Text(T("балл", "ball")).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            Spacer(minLength: 2)
            KmHero(km: w.km, size: 26)
            Text(usualText(w)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(1).minimumScaleFactor(0.75)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
struct WeekMedium: View {
    let w: WeekM
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 11) {
                Rings(score: w.score, road: w.usual == nil ? nil : w.km / (w.usual ?? 1), side: 60)
                VStack(alignment: .leading, spacing: 1) {
                    KmHero(km: w.km, size: 25)
                    Text(usualText(w)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
                Spacer(minLength: 2)
                VStack(alignment: .trailing, spacing: 5) {
                    if let s = w.score { ScoreBadge(score: s, size: 11) }
                    Money(risk: w.risk, size: 11)
                }
            }
            WeekRow(w: w, side: 27)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
struct Tile: View {
    let v: String; let l: String
    var body: some View {
        VStack(spacing: 1) {
            Text(v).font(.system(size: 14, weight: .heavy, design: .rounded)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
            Text(l).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
        }.frame(maxWidth: .infinity)
    }
}
struct WeekLarge: View {
    let w: WeekM; var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 9 : 12) {
            HStack {
                Text(T("Неделя", "Hafta")).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                Spacer()
                Text(T("9–15 нояб.", "9–15-noy")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
            HStack(spacing: 14) {
                Rings(score: w.score, road: w.usual == nil ? nil : w.km / (w.usual ?? 1), side: compact ? 84 : 100)
                VStack(alignment: .leading, spacing: 3) {
                    KmHero(km: w.km, size: 34)
                    Text(usualText(w)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                    HStack(spacing: 7) {
                        if let s = w.score { ScoreBadge(score: s, size: 12) }
                        Money(risk: w.risk, size: 12)
                    }
                }
                Spacer(minLength: 0)
            }
            WeekRow(w: w, side: 34)
            VStack(spacing: 5) {
                GeometryReader { g in
                    HStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 3).fill(hex(0x9A85FF)).frame(width: g.size.width * 0.62)
                        RoundedRectangle(cornerRadius: 3).fill(hex(0x3BE3B0))
                    }
                }.frame(height: 7)
                HStack {
                    Label { Text(T("Работа и дом 73 км", "Ish va uy 73 km")) } icon: { Circle().fill(hex(0x9A85FF)).frame(width: 7, height: 7) }
                    Spacer()
                    Label { Text(T("Другое 45 км", "Boshqa 45 km")) } icon: { Circle().fill(hex(0x3BE3B0)).frame(width: 7, height: 7) }
                }.font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).labelStyle(TightLabel())
            }
            if !compact {
                HStack(spacing: 8) {
                    Image(systemName: "mappin.and.ellipse").font(.system(size: 12, weight: .bold)).foregroundStyle(hex(0xFF7A70))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(T("Где теряете баллы", "Ballarni qayerda yo‘qotasiz")).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                        Text("Юнусабад, Амира Темура").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    }
                    Spacer()
                    Text(verbatim: "×4").font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(hex(0xFF7A70))
                }.padding(.horizontal, 10).padding(.vertical, 7).background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
struct TightLabel: LabelStyle { func makeBody(configuration: Configuration) -> some View { HStack(spacing: 4) { configuration.icon; configuration.title } } }

/// Понедельник и пустая неделя — не «готов к поездке», а прошлая неделя и приглашение.
struct WeekMonday: View {
    let fam: WidgetFamily
    var body: some View {
        let ring = Rings(score: 0, road: 0, side: fam == .systemSmall ? 62 : 72)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ring
                if fam != .systemSmall {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(T("Новая неделя", "Yangi hafta")).font(.system(size: 19, weight: .heavy)).foregroundStyle(.white)
                        Text(T("обычно 165 км", "odatda 165 km")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                    }
                }
                Spacer(minLength: 0)
            }
            if fam == .systemSmall {
                Spacer(minLength: 4)
                Text(T("Новая неделя", "Yangi hafta")).font(.system(size: 17, weight: .heavy)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
            } else { Spacer(minLength: 6) }
            Text(T("Прошлая: 165 км · балл 72", "O‘tgan: 165 km · ball 72")).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1).minimumScaleFactor(0.75)
            if fam == .systemLarge {
                Spacer(minLength: 10)
                WeekRow(w: WeekM(km: 0, usual: 165, score: nil, risk: nil, days: Array(repeating: nil, count: 7), today: 0), side: 34)
                Spacer(minLength: 10)
                HStack(spacing: 0) { Tile(v: "486 км", l: T("за месяц", "oyiga")); Tile(v: "12 400 км", l: T("всего", "jami")); Tile(v: T("2 штрафа", "2 jarima"), l: T("за месяц", "oyiga")) }
                    .padding(.vertical, 8).background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Spacer(minLength: 0)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
struct WeekFirst: View {
    let fam: WidgetFamily
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if fam != .systemSmall { Spacer(minLength: 0) }
            Rings(score: 0, road: 0, side: fam == .systemSmall ? 54 : 60)
            if fam == .systemSmall { Spacer(minLength: 0) }
            Text(T("Первая поездка", "Birinchi safar")).font(.system(size: 17, weight: .heavy)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
            Text(T("Кольца заполнятся сами", "Halqalar o‘zi to‘ladi")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).lineLimit(2)
            if fam != .systemSmall { Spacer(minLength: 0) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: Вариант Б — по теме системы, столбики «дорога/другое»
struct WeekBars: View {
    var body: some View {
        let parts: [(Double, Double, Bool)] = [(0.55, 0.25, false), (0.5, 0.1, false), (0.6, 0.4, true), (0.5, 0.1, false), (0, 0, false), (0, 0, false), (0, 0, false)]
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(T("Неделя", "Hafta")).font(.system(size: 12, weight: .semibold)).foregroundStyle(SW.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(verbatim: "118").font(.system(size: 34, weight: .heavy, design: .rounded))
                    Text(T("км", "km")).font(.system(size: 16, weight: .bold, design: .rounded))
                }.foregroundStyle(SW.primary)
                Text(usualText(wFull)).font(.system(size: 11)).foregroundStyle(SW.secondary)
                Spacer(minLength: 2)
                HStack(spacing: 6) {
                    Text(T("балл 67", "ball 67")).font(.system(size: 11, weight: .heavy)).foregroundStyle(SW.warning)
                    Text("≈ 2,2 млн").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(SW.camera)
                }
            }
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(0..<7, id: \.self) { i in
                    VStack(spacing: 3) {
                        if parts[i].2 { Circle().fill(SW.camera).frame(width: 5, height: 5) }
                        VStack(spacing: 1.5) {
                            if parts[i].1 > 0 { RoundedRectangle(cornerRadius: 3).fill(St.other).frame(width: 12, height: parts[i].1 * 74) }
                            if parts[i].0 > 0 { RoundedRectangle(cornerRadius: 3).fill(St.commute).frame(width: 12, height: parts[i].0 * 74) }
                            if parts[i].0 == 0 { RoundedRectangle(cornerRadius: 1).fill(SW.primary.opacity(0.12)).frame(width: 12, height: 3) }
                        }
                        Text(letters[i]).font(.system(size: 9, weight: i == 3 ? .heavy : .regular)).foregroundStyle(i == 3 ? SW.primary : SW.tertiary)
                    }.frame(maxWidth: .infinity)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Дорога
struct Go: View { var size: CGFloat = 26
    var body: some View {
        Image(systemName: "arrow.up.right").font(.system(size: size * 0.46, weight: .heavy)).foregroundStyle(St.onAction)
            .frame(width: size, height: size).background(St.action, in: Circle())
    }
}
struct Mins: View { let t: String; var size: CGFloat = 36; var color: Color = SW.primary
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(t).font(.system(size: size, weight: .heavy, design: .rounded))
            Text(T("мин", "daq")).font(.system(size: size * 0.45, weight: .bold, design: .rounded))
        }.foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
    }
}
struct CommuteSmallM: View {
    let toWork: Bool; let time: String; let sub: String; var note: String? ; var jam = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: toWork ? "briefcase.fill" : "house.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(SW.accent)
                Text(toWork ? T("На работу", "Ishga") : T("Домой", "Uyga")).font(.system(size: 13, weight: .semibold)).foregroundStyle(SW.secondary).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 2)
                Go()
            }
            Spacer(minLength: 2)
            Mins(t: time, size: 38)
            Text(sub).font(.system(size: 12)).foregroundStyle(SW.secondary).lineLimit(1).minimumScaleFactor(0.75)
            if let note { Text(note).font(.system(size: 12, weight: .semibold)).foregroundStyle(jam ? SW.warning : SW.success).lineLimit(1).minimumScaleFactor(0.75) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
struct CommuteCard: View {
    let toWork: Bool; let time: String?; let sub: String; let primary: Bool; var slots: [Double]? = nil
    var body: some View {
        let ink: Color = primary ? .white : SW.primary
        let dim: Color = primary ? .white.opacity(0.85) : SW.secondary
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: toWork ? "briefcase.fill" : "house.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(ink)
                Text(toWork ? T("На работу", "Ishga") : T("Домой", "Uyga")).font(.system(size: 13, weight: .semibold)).foregroundStyle(dim).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if primary { Go(size: 22) }
            }
            Spacer(minLength: 0)
            if let time { Mins(t: time, size: 30, color: ink) } else { Text(T("Маршрут", "Yo‘nalish")).font(.system(size: 20, weight: .heavy)).foregroundStyle(ink).lineLimit(1).minimumScaleFactor(0.7) }
            Text(sub).font(.system(size: 11, weight: primary ? .semibold : .regular)).foregroundStyle(dim).lineLimit(2).minimumScaleFactor(0.8).fixedSize(horizontal: false, vertical: true)
        }.padding(11).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
         .background(primary ? SW.accentFill : St.quiet, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
struct CommuteMediumM: View {
    var body: some View {
        HStack(spacing: 8) {
            CommuteCard(toWork: true, time: "~44", sub: T("пробки +8 · выезд до 8:10", "tirbandlik +8 · 8:10 gacha"), primary: true)
            CommuteCard(toWork: false, time: "39", sub: T("обычно", "odatda"), primary: false).frame(width: 112)
        }.padding(-6).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
struct SetupCard: View { let icon: String; let t: String; let sub: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: icon).font(.system(size: 14, weight: .bold)).foregroundStyle(SW.accent)
            Spacer(minLength: 0)
            Text(t).font(.system(size: 15, weight: .heavy)).foregroundStyle(SW.primary).lineLimit(1).minimumScaleFactor(0.8)
            Text(sub).font(.system(size: 11)).foregroundStyle(SW.accent).lineLimit(1)
        }.padding(11).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
         .background(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(SW.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}
struct CommuteSetupMedium: View {
    var body: some View {
        HStack(spacing: 8) {
            SetupCard(icon: "house.fill", t: T("Дом", "Uy"), sub: T("Указать", "Belgilash"))
            SetupCard(icon: "briefcase.fill", t: T("Работа", "Ish"), sub: T("Указать", "Belgilash"))
        }.padding(-6).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
struct CommuteSetupSmall: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "house.fill"); Image(systemName: "briefcase.fill")
            }.font(.system(size: 15, weight: .bold)).foregroundStyle(SW.accent)
            Spacer(minLength: 0)
            Text(T("Домой — одним касанием", "Uyga — bir teginishda")).font(.system(size: 15, weight: .heavy)).foregroundStyle(SW.primary).lineLimit(3).minimumScaleFactor(0.8)
            Text(T("Укажите адреса", "Manzillarni belgilang")).font(.system(size: 12, weight: .semibold)).foregroundStyle(SW.accent).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
struct CommuteLargeM: View {
    var body: some View {
        let values: [Double] = [34, 35, 36, 38, 41, 44, 47, 46, 43, 40, 38, 37]
        let labels = ["7:00", "", "", "7:45", "", "", "8:30", "", "", "9:15", "", ""]
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                CommuteCard(toWork: true, time: "~44", sub: T("пробки +8 · выезд до 8:10", "tirbandlik +8 · 8:10 gacha"), primary: true)
                CommuteCard(toWork: false, time: "39", sub: T("обычно", "odatda"), primary: false).frame(width: 112)
            }.frame(height: 128)
            VStack(alignment: .leading, spacing: 6) {
                Text(T("Когда выезжать", "Qachon chiqish kerak")).font(.system(size: 13, weight: .semibold)).foregroundStyle(SW.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(T("в 7:45 — 36 мин", "7:45 da — 36 daq")).font(.system(size: 20, weight: .heavy, design: .rounded)).foregroundStyle(SW.success)
                    Text(T("по вашим поездкам", "safarlaringiz bo‘yicha")).font(.system(size: 11)).foregroundStyle(SW.tertiary)
                }
                HStack(alignment: .bottom, spacing: 5) {
                    ForEach(0..<12, id: \.self) { i in
                        VStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(i == 3 ? SW.success : i == 5 ? SW.accent : SW.accent.opacity(0.28))
                                .frame(height: (values[i] - 28) * 5.2)
                            Text(labels[i]).font(.system(size: 9, weight: .medium)).foregroundStyle(SW.tertiary).fixedSize()
                                .frame(height: 11)
                        }.frame(maxWidth: .infinity)
                    }
                }
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, -6).padding(.top, -6).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Листы
@MainActor func dark<V: View>(_ size: CGSize, _ l: String = "", _ v: () -> V) -> Shot {
    snap(v().padding(16).frame(width: size.width, height: size.height).background(St.ground)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)).environment(\.colorScheme, .dark), l)
}
@MainActor func adp<V: View>(_ size: CGSize, _ s: ColorScheme, _ l: String = "", _ v: () -> V) -> Shot {
    snap(v().padding(16).frame(width: size.width, height: size.height).background(SW.background)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)).environment(\.colorScheme, s), l)
}
@MainActor func lk<V: View>(_ size: CGSize, _ l: String = "", _ v: () -> V) -> Shot {
    let raw = snap(v().frame(width: size.width, height: size.height).foregroundStyle(.white).environment(\.colorScheme, .dark))
    return snap(Image(decorative: raw.image, scale: Scale).renderingMode(.template).foregroundStyle(.white.opacity(0.92)).padding(6).background(Wallpaper()), l)
}
struct GlassTile<V: View>: View { let size: CGSize; let tinted: Bool; @ViewBuilder let v: () -> V
    var body: some View {
        ZStack { RoundedRectangle(cornerRadius: 22, style: .continuous).fill(tinted ? Color.black.opacity(0.55) : Color.white.opacity(0.16)); v().padding(16) }
            .frame(width: size.width, height: size.height).padding(8).background(Wallpaper())
    }
}

@MainActor func mockSheets() {
    let cSmallW = CommuteSmallM(toWork: true, time: "~44", sub: T("в это время · обычно 42", "shu vaqtda · odatda 42"), note: T("пробки +8 мин", "tirbandlik +8 daq"), jam: true)
    let cSmallAdv = CommuteSmallM(toWork: true, time: "42", sub: T("обычно", "odatda"), note: T("выезд до 8:10", "8:10 gacha chiqing"))
    let cSmallH = CommuteSmallM(toWork: false, time: "39", sub: T("обычно", "odatda"), note: T("пробки +10 мин", "tirbandlik +10 daq"), jam: true)
    sheet("mock_1_commute_\(LANG)", "1. «Дорога» — главный виджет: нажатие строит маршрут", [
        Row(title: "Малый: нажатие — маршрут и экран «Поехали»; жёлтая стрелка говорит, что виджет действует", shots: [
            adp(Size.small, .light, "сейчас + пробки") { cSmallW }, adp(Size.small, .dark, "ночь") { cSmallW },
            adp(Size.small, .light, "только норма и совет") { cSmallAdv }, adp(Size.small, .dark, "вечер") { cSmallH }, adp(Size.smallSE, .light, "SE 148") { cSmallW }]),
        Row(title: "Средний: две зоны нажатия, оба направления", shots: [
            adp(Size.medium, .light, "утро") { CommuteMediumM() }, adp(Size.medium, .dark, "ночь") { CommuteMediumM() }, adp(Size.mediumSE, .light, "SE 321") { CommuteMediumM() }]),
        Row(title: "Дом и работа заданы, поездок меньше трёх: маршрут уже работает, времени ещё нет", shots: [
            adp(Size.medium, .light) { HStack(spacing: 8) { CommuteCard(toWork: true, time: nil, sub: T("время — после 3 поездок", "vaqt — 3 safardan keyin"), primary: true); CommuteCard(toWork: false, time: nil, sub: T("время — после 3 поездок", "vaqt — 3 safardan keyin"), primary: false).frame(width: 112) }.padding(-6).frame(maxWidth: .infinity, maxHeight: .infinity) }]),
        Row(title: "Адреса не заданы: действие вместо обещания «после трёх поездок»", shots: [
            adp(Size.small, .light) { CommuteSetupSmall() }, adp(Size.medium, .light) { CommuteSetupMedium() }, adp(Size.medium, .dark) { CommuteSetupMedium() }]),
        Row(title: "Большой (новый размер): «Когда выезжать» — как почасовой прогноз, из уже записанных окон", shots: [
            adp(Size.large, .light) { CommuteLargeM() }, adp(Size.large, .dark) { CommuteLargeM() }]),
    ])

    sheet("mock_2_week_\(LANG)", "2. «Неделя» кольцами — набор Theme.Stats и кольца дня из плана 59", [
        Row(title: "Вариант А (рекомендую): всегда тёмная, как календарь «Итогов». Внешнее кольцо — аккуратность, внутреннее — пробег к обычной неделе", shots: [
            dark(Size.small, "full, балл 67") { WeekSmall(w: wFull) }, dark(Size.small, "full, балл 91") { WeekSmall(w: wClean) }, dark(Size.medium, "средний: 7 дней кольцами") { WeekMedium(w: wFull) }]),
        Row(title: "Большой умещается на всех экранах (сейчас содержимое 373 pt при 322 доступных)", shots: [
            dark(Size.large, "экран 390") { WeekLarge(w: wFull) }, dark(Size.largeSE, "SE: без «Где теряете»") { WeekLarge(w: wFull, compact: true) }]),
        Row(title: "Мало данных: без внутреннего кольца, столбиков и сравнений", shots: [
            dark(Size.small, "few") { WeekSmall(w: wFew) }, dark(Size.medium, "few") { WeekMedium(w: wFew) }]),
        Row(title: "Понедельник: прошлая неделя вместо «Готов к поездке» у того, кто ездит год", shots: [
            dark(Size.small) { WeekMonday(fam: .systemSmall) }, dark(Size.medium) { WeekMonday(fam: .systemMedium) }, dark(Size.large) { WeekMonday(fam: .systemLarge) }]),
        Row(title: "Новый водитель", shots: [dark(Size.small) { WeekFirst(fam: .systemSmall) }, dark(Size.medium) { WeekFirst(fam: .systemMedium) }]),
        Row(title: "Вариант Б: по теме системы, столбики «дорога на работу / другое» фиолетовым и мятным", shots: [
            adp(Size.medium, .light) { WeekBars() }, adp(Size.medium, .dark) { WeekBars() }]),
    ])

    // Локскрин и Пункт управления
    func circ(_ top: String, _ v: String) -> some View {
        ZStack { Circle().fill(.white.opacity(0.14)); VStack(spacing: 0) { Image(systemName: top).font(.system(size: 15, weight: .bold)); Text(v).font(.system(size: 16, weight: .heavy, design: .rounded)).minimumScaleFactor(0.6) } }
    }
    func rect(_ a: String, _ b: String, _ c: String) -> some View {
        VStack(alignment: .leading, spacing: 1) { Text(a).font(.system(size: 12, weight: .semibold)); Text(b).font(.system(size: 17, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.8); Text(c).font(.system(size: 11)).opacity(0.8).lineLimit(1).minimumScaleFactor(0.8) }.frame(maxWidth: .infinity, alignment: .leading)
    }
    func weekRect(_ km: String, _ b: String, _ dots: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(T("Неделя", "Hafta")).font(.system(size: 12, weight: .semibold))
            Text(km + " · " + b).font(.system(size: 17, weight: .heavy, design: .rounded)).lineLimit(1).minimumScaleFactor(0.8)
            HStack(spacing: 4) { ForEach(0..<7, id: \.self) { i in Group { if dots[i] == 2 { Circle().fill(.white) } else if dots[i] == 1 { Circle().fill(.white.opacity(0.55)) } else { Circle().stroke(.white.opacity(0.4), lineWidth: 1) } }.frame(width: 7, height: 7) } }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    func inl(_ t: String) -> some View { Text(t).font(.system(size: 15)).lineLimit(1).frame(maxWidth: .infinity) }
    func ctrl(_ icon: String, _ on: Bool, _ fill: Color) -> some View {
        Image(systemName: icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(on ? St.onAction : .white).frame(width: 66, height: 66).background(on ? fill : Color.white.opacity(0.14), in: Circle())
    }
    func ctrlShot(_ i: String, _ on: Bool, _ fill: Color, _ l: String) -> Shot {
        snap(ctrl(i, on, fill).padding(8).background(hex(0x1B1F26), in: RoundedRectangle(cornerRadius: 16, style: .continuous)).environment(\.colorScheme, .dark), l)
    }
    sheet("mock_3_lock_control_\(LANG)", "3. Экран блокировки и Пункт управления", [
        Row(title: "«Дорога» на локскрине: круглый — новый, нажатие ведёт к маршруту после разблокировки", shots: [
            lk(Size.circular, "") { circ("briefcase.fill", "~44") }, lk(Size.rectangular, "как есть, чище") { rect(T("На работу", "Ishga"), T("~44 мин", "~44 daq"), T("выезд до 8:10", "8:10 gacha chiqing")) }, lk(Size.inline) { inl(T("На работу ~44 мин · до 8:10", "Ishga ~44 daq · 8:10 gacha")) }]),
        Row(title: "Приватный режим (настройка): без слов «дом» и «работа»", shots: [
            lk(Size.circular) { circ("road.lanes", "~44") }, lk(Size.rectangular) { rect(T("Дорога", "Yo‘l"), T("~44 мин", "~44 daq"), T("пробки +8", "tirbandlik +8")) }]),
        Row(title: "«Неделя»: дни точками; пустое — без нулей", shots: [
            lk(Size.circular) { ZStack { Circle().fill(.white.opacity(0.14)); Gauge(value: 0.72) { EmptyView() } currentValueLabel: { Text(verbatim: "118").font(.system(size: 15, weight: .heavy, design: .rounded)) }.gaugeStyle(.accessoryCircularCapacity) } },
            lk(Size.rectangular) { weekRect(T("118 км", "118 km"), T("балл 67", "ball 67"), [1, 1, 1, 2, 0, 0, 0]) }, lk(Size.inline) { inl(T("118 из 165 км · балл 67", "118/165 km · ball 67")) }]),
        Row(title: "«Неделя» без поездок", shots: [
            lk(Size.circular) { circ("car.fill", "—") }, lk(Size.rectangular) { rect(T("Неделя", "Hafta"), T("Поездок нет", "Safar yo‘q"), T("обычно 165 км", "odatda 165 km")) }, lk(Size.inline) { inl(T("На этой неделе поездок нет", "Bu hafta safar yo‘q")) }]),
        Row(title: "Пункт управления, кнопка действия: кнопки ниже — 1×1; Поездка и Звук — переключатели", shots: [
            ctrlShot("car.fill", true, St.action, T("Поездка (идёт)", "Safar")), ctrlShot("car.fill", false, St.action, T("Поездка", "Safar")), ctrlShot("exclamationmark.triangle.fill", true, St.action, T("Радар!", "Radar!")), ctrlShot("speaker.slash.fill", false, St.action, T("Звук", "Ovoz")), ctrlShot("house.fill", false, St.action, T("Домой", "Uyga")), ctrlShot("briefcase.fill", false, St.action, T("На работу", "Ishga"))]),
    ], note: "Система сама рисует кнопки Пункта управления; здесь показан только набор.")

    // Live Activity
    let w = CameraActivityWidget()
    let st = cameraNear
    let expanded = snap(VStack(spacing: 6) {
        HStack { w.typeIcon(st, isStale: false); Spacer()
            Text(format(150)).font(.system(.title3, design: .rounded).bold()).foregroundStyle(WTheme.level(3))
            LimitSign(limit: 60, size: 30) }
        VStack(alignment: .leading, spacing: 4) {
            Text("Амира Темура, 14").font(.system(.footnote)).foregroundStyle(WTheme.secondary).lineLimit(1)
            GhostLine(state: st); ActivityButtons(state: st, height: 34).padding(.top, 2)
        }
    }.padding(16).frame(width: 370).background(RoundedRectangle(cornerRadius: 40, style: .continuous).fill(.black)).environment(\.colorScheme, .dark), T("остров: знак ограничения рядом с расстоянием", ""))
    let finish = snap(HStack(spacing: 13) {
        Rings(score: 81, road: 0.8, side: 58)
        VStack(alignment: .leading, spacing: 3) {
            Text(T("Поездка сохранена", "Safar saqlandi")).font(.system(.headline)).foregroundStyle(WTheme.primary)
            Text(T("21,4 км · 34 мин · камер 6", "21,4 km · 34 daq · 6 kamera")).font(.system(.caption)).foregroundStyle(WTheme.secondary)
            Text(T("Без штрафов", "Jarimalarsiz")).font(.system(.caption).weight(.semibold)).foregroundStyle(WTheme.clear)
        }
        Spacer(minLength: 0)
        Text(verbatim: "81").font(.system(size: 34, weight: .heavy, design: .rounded)).foregroundStyle(tierText(81))
    }.padding(14).frame(width: 370).background(WTheme.background.opacity(0.92)).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous)).environment(\.colorScheme, .dark), T("новый финальный кадр: держится 10 минут после конца поездки, нажатие — деталка", ""))
    sheet("mock_4_activity_\(LANG)", "4. Live Activity: основа остаётся, две правки", [Row(title: "", shots: [expanded, finish])], ground: Color(white: 0.75))

    // Тонирование и узкие экраны
    let tint = Color(red: 1, green: 0.78, blue: 0.45)
    func tile<V: View>(_ size: CGSize, _ t: Bool, _ l: String, _ v: @escaping () -> V) -> Shot { snap(GlassTile(size: size, tinted: t, v: v), l) }
    func ringsMono(_ a: Color, _ b: Color, _ side: CGFloat) -> some View { Rings(score: 67, road: 0.72, side: side, a: a, b: b) }
    func tintedWeek(_ a: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) { ringsMono(a, .white, 70); Spacer(); VStack(alignment: .trailing, spacing: 0) { Text(verbatim: "67").font(.system(size: 24, weight: .heavy, design: .rounded)).foregroundStyle(a); Text(T("балл", "ball")).font(.system(size: 10)).foregroundStyle(.white.opacity(0.7)) } }
            Spacer(minLength: 2)
            KmHero(km: 118, size: 26)
            Text(usualText(wFull)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
    func tintedCommute(_ a: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) { Image(systemName: "briefcase.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(a); Text(T("На работу", "Ishga")).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.75)).lineLimit(1).fixedSize(); Spacer(); Image(systemName: "arrow.up.right.circle.fill").font(.system(size: 24)).foregroundStyle(a) }
            Spacer(minLength: 2)
            Mins(t: "~44", size: 38, color: .white)
            Text(T("в это время · обычно 42", "shu vaqtda · odatda 42")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
            Text(T("пробки +8 мин", "tirbandlik +8 daq")).font(.system(size: 12, weight: .semibold)).foregroundStyle(a)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
    sheet("mock_5_tinted_\(LANG)", "5. Тонированный и «Прозрачный» (widgetAccentable у колец и акцента, значки без заливок)", [
        Row(title: "", shots: [tile(Size.small, true, T("Неделя, тонированный", "")) { tintedWeek(tint) }, tile(Size.small, true, T("Дорога, тонированный", "")) { tintedCommute(tint) },
                               tile(Size.small, false, T("Неделя, прозрачный", "")) { tintedWeek(.white) }, tile(Size.small, false, T("Дорога, прозрачный", "")) { tintedCommute(.white) }])
    ], note: "Макет: как должно получиться, а не снимок системы.")
}
