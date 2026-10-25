// Картинки аудита маршрутов (29.E): спецификация route_audit.py render → PNG.
//
//   swift render_routes.swift shots/*.spec.json
//
// Только macOS (CoreGraphics + ImageIO + CoreText), без зависимостей: фон —
// дороги OSM по классам (махалля и service — сиреневым, чтобы транзит через
// них было видно сразу), сверху варианты маршрута и метки дефектов.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Spec: Decodable {
    struct Route: Decodable { let rank: Int; let p: [[Double]]; let label: String }
    struct Marker: Decodable { let p: [Double]; let kind: String; let text: String? }
    let title: String
    let bbox: [Double]          // lat0, lon0, lat1, lon1
    let width: Int
    let height: Int
    let roads: [[Road]]
    let routes: [Route]
    let markers: [Marker]
    enum Road: Decodable {
        case style(Int), line([[Double]])
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(Int.self) { self = .style(s) } else { self = .line(try c.decode([[Double]].self)) }
        }
    }
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// стиль фона: цвет, толщина
let roadStyles: [Int: (CGColor, CGFloat)] = [
    0: (color(0xE07B39), 4.0), 1: (color(0xF0A040), 3.2), 2: (color(0xE8C860), 2.6),
    3: (color(0xB8B8B8), 1.8), 4: (color(0xCFCFCF), 1.0), 5: (color(0xC79BE0), 1.2), 6: (color(0xB09070), 0.8),
]
let routeColors: [CGColor] = [color(0x1F5FD6, 0.85), color(0x1FA35A, 0.8), color(0xB0309E, 0.8)]

func render(_ path: String) throws {
    let spec = try JSONDecoder().decode(Spec.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let w = spec.width, h = spec.height
    let lat0 = spec.bbox[0], lon0 = spec.bbox[1], lat1 = spec.bbox[2], lon1 = spec.bbox[3]
    // Равноугольная проекция вокруг середины рамки, вписать с сохранением пропорций.
    let k = cos((lat0 + lat1) / 2 * .pi / 180)
    let spanX = (lon1 - lon0) * k, spanY = lat1 - lat0
    let scale = min(Double(w - 40) / spanX, Double(h - 110) / spanY)
    let offX = (Double(w) - spanX * scale) / 2, offY = 96.0
    func pt(_ lon: Double, _ lat: Double) -> CGPoint {
        CGPoint(x: offX + (lon - lon0) * k * scale, y: offY + (lat - lat0) * scale)
    }
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.setFillColor(color(0xF7F6F2)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    // фон: сначала мелкие, сверху крупные
    let roads: [(Int, [[Double]])] = spec.roads.compactMap { pair in
        guard pair.count == 2, case .style(let s) = pair[0], case .line(let l) = pair[1] else { return nil }
        return (s, l)
    }
    for (style, line) in roads.sorted(by: { $0.0 > $1.0 }) {
        guard let (c, width) = roadStyles[style], line.count >= 2 else { continue }
        ctx.setStrokeColor(c); ctx.setLineWidth(width)
        ctx.beginPath(); ctx.move(to: pt(line[0][0], line[0][1]))
        for p in line.dropFirst() { ctx.addLine(to: pt(p[0], p[1])) }
        ctx.strokePath()
    }
    // варианты: последний снизу, первый (рекомендованный движком) сверху
    for route in spec.routes.reversed() {
        guard route.p.count >= 2 else { continue }
        ctx.setStrokeColor(routeColors[route.rank % routeColors.count])
        ctx.setLineWidth(route.rank == 0 ? 6 : 5)
        ctx.beginPath(); ctx.move(to: pt(route.p[0][0], route.p[0][1]))
        for p in route.p.dropFirst() { ctx.addLine(to: pt(p[0], p[1])) }
        ctx.strokePath()
    }
    func text(_ s: String, at p: CGPoint, size: CGFloat, color c: CGColor, bold: Bool = false) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let attrs = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: c] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, s as CFString, attrs))
        ctx.textPosition = p
        CTLineDraw(line, ctx)
    }
    for m in spec.markers {
        let p = pt(m.p[0], m.p[1])
        let (fill, r): (CGColor, CGFloat) = switch m.kind {
        case "from": (color(0x22AA44), 9)
        case "to": (color(0xE03030), 9)
        default: (color(0x111111), 7)
        }
        ctx.setFillColor(fill)
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        ctx.setStrokeColor(color(0xFFFFFF)); ctx.setLineWidth(2)
        ctx.strokeEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        if let t = m.text { text(t, at: CGPoint(x: p.x + 10, y: p.y + 6), size: 15, color: color(0x111111), bold: true) }
    }
    // шапка (CoreGraphics — начало координат снизу: подписи внизу картинки)
    ctx.setFillColor(color(0xFFFFFF, 0.92)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: 84))
    text(spec.title, at: CGPoint(x: 16, y: 56), size: 20, color: color(0x111111), bold: true)
    var x: CGFloat = 16
    for route in spec.routes {
        ctx.setFillColor(routeColors[route.rank % routeColors.count])
        ctx.fill(CGRect(x: x, y: 22, width: 26, height: 8))
        text(route.label, at: CGPoint(x: x + 32, y: 20), size: 15, color: color(0x222222))
        x += 250
    }
    text("сиреневый — living_street/service", at: CGPoint(x: CGFloat(w) - 280, y: 20), size: 13, color: color(0x8050A0))
    // картинка в CG перевёрнута относительно карты: север вверх
    guard let image = ctx.makeImage() else { return }
    let out = URL(fileURLWithPath: path.replacingOccurrences(of: ".spec.json", with: ".png"))
    guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("ok", out.lastPathComponent)
}

for path in CommandLine.arguments.dropFirst() {
    do { try render(path) } catch { print("ошибка", path, error) }
}
