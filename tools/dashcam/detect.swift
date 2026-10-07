// Черновые детекторы для кадров регистратора — без обучения, на Vision и
// разборе цвета. Это кандидаты для разметки, а не истина.
//
//   detect detect LIST     — LIST: файл со списком JPEG (по строке); в stdout
//                            JSON-строка на кадр: {"f": путь, "d": [сработки]}
//   detect crop SPEC       — SPEC: JSON-строки {"src","dst","box":[x,y,w,h],
//                            "keep":[x,y,w,h]}; вырезка с размытием лиц и
//                            текста (номеров) вне рамки объекта
//
// Кадр детекторов — уже без верхней полосы и капота (frames.py), 1280 px.
// Классы:
//   speed_limit — красное кольцо с числом из ряда 20…120 внутри. Сначала
//     цвет (кольцо: доля красного по окружности, светлая середина), потом
//     VNRecognizeTextRequest на вырезке середины. Число вне ряда — не знак
//     ограничения, текст не выводится никогда (номера машин — тоже текст).
//   traffic_light — горящая секция: яркое насыщенное красное/жёлтое/зелёное
//     округлое пятно в верхней части кадра, вокруг — тёмный корпус. Пары по
//     горизонтали внизу (задние фонари), солнце и небо отсекаются.
//   crossing — синий квадрат с белым треугольником (5.19).
import AppKit
import CoreImage
import Foundation
import ImageIO
import Vision

// MARK: - изображение

struct RGBA {
    let w: Int, h: Int
    var px: [UInt8]
    @inline(__always) func r(_ x: Int, _ y: Int) -> Int { Int(px[(y * w + x) * 4]) }
    @inline(__always) func g(_ x: Int, _ y: Int) -> Int { Int(px[(y * w + x) * 4 + 1]) }
    @inline(__always) func b(_ x: Int, _ y: Int) -> Int { Int(px[(y * w + x) * 4 + 2]) }
}

func loadCG(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func rgba(_ cg: CGImage) -> RGBA {
    let w = cg.width, h = cg.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpaceCreateDeviceRGB()
    px.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return RGBA(w: w, h: h, px: px)
}

/// HSV: h 0…360, s 0…1, v 0…1.
@inline(__always) func hsv(_ r: Int, _ g: Int, _ b: Int) -> (Float, Float, Float) {
    let mx = max(r, max(g, b)), mn = min(r, min(g, b))
    let v = Float(mx) / 255
    if mx == 0 { return (0, 0, 0) }
    let d = Float(mx - mn)
    let s = d / Float(mx)
    if d == 0 { return (0, 0, v) }
    var h: Float
    if mx == r { h = 60 * (Float(g - b) / d) }
    else if mx == g { h = 60 * (Float(b - r) / d) + 120 }
    else { h = 60 * (Float(r - g) / d) + 240 }
    if h < 0 { h += 360 }
    return (h, s, v)
}

// MARK: - связные компоненты

struct Blob {
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1, n = 0
    var sx = 0, sy = 0
    var w: Int { maxX - minX + 1 }
    var h: Int { maxY - minY + 1 }
    var cx: Double { Double(sx) / Double(max(n, 1)) }
    var cy: Double { Double(sy) / Double(max(n, 1)) }
}

/// 8-связные компоненты маски в прямоугольнике [0,w)×[0,ylim).
func components(_ mask: [Bool], _ w: Int, _ ylim: Int, maxBlob: Int = 40000) -> [Blob] {
    var seen = [Bool](repeating: false, count: mask.count)
    var out: [Blob] = []
    var stack: [Int] = []
    for start in 0..<(w * ylim) where mask[start] && !seen[start] {
        var b = Blob()
        stack.removeAll(keepingCapacity: true)
        stack.append(start)
        seen[start] = true
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            b.n += 1; b.sx += x; b.sy += y
            if x < b.minX { b.minX = x }; if x > b.maxX { b.maxX = x }
            if y < b.minY { b.minY = y }; if y > b.maxY { b.maxY = y }
            for dy in -1...1 {
                let yy = y + dy
                if yy < 0 || yy >= ylim { continue }
                for dx in -1...1 {
                    let xx = x + dx
                    if xx < 0 || xx >= w || (dx == 0 && dy == 0) { continue }
                    let j = yy * w + xx
                    if mask[j] && !seen[j] { seen[j] = true; stack.append(j) }
                }
            }
        }
        if b.n <= maxBlob { out.append(b) }
    }
    return out
}

func dilate(_ m: [Bool], _ w: Int, _ h: Int) -> [Bool] {
    var o = m
    for y in 0..<h {
        for x in 0..<w where m[y * w + x] {
            for dy in -1...1 {
                let yy = y + dy
                if yy < 0 || yy >= h { continue }
                for dx in -1...1 {
                    let xx = x + dx
                    if xx >= 0 && xx < w { o[yy * w + xx] = true }
                }
            }
        }
    }
    return o
}

struct Det: Encodable {
    let cls: String
    var value: Int? = nil
    var color: String? = nil
    let x: Double, y: Double, w: Double, h: Double
    let conf: Double
}

// MARK: - знак ограничения скорости

let ALLOWED: Set<Int> = [20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120]
let SIGN_YLIM: Double = 0.80          // верхние ~65 % исходного кадра
let LIGHT_YLIM: Double = 0.66         // верхние ~55 % исходного кадра
// Горизонт — строка 615 исходного кадра (калибровка агента полос): в кадре
// детекторов (строки 70…864) это (615 − 70) / 794 ≈ 0,686.
let HORIZON: Double = 0.686
// Полоса «у горизонта» для светофоров: там же задние фонари автобусов и грузовиков.
let LOW_BAND: Double = 0.58

@inline(__always) func isRed(_ r: Int, _ g: Int, _ b: Int) -> Bool {
    let (h, s, v) = hsv(r, g, b)
    // Тонкое кольцо на сжатом кадре размыто цветностью JPEG: красный уходит в
    // розовый (с белым) и в пурпур (с синим), насыщенность падает до ~0.3.
    return (h >= 318 || h <= 20) && s >= 0.28 && v >= 0.25
}

/// Красный кант знака в тени и против солнца: тёмный и блёклый (s ~0,2, v ~0,2–0,4).
/// Только для сита знаков ограничения — дальше всё решает прочитанное число.
@inline(__always) func isShadedRed(_ r: Int, _ g: Int, _ b: Int) -> Bool {
    if isRed(r, g, b) { return true }
    let (h, s, v) = hsv(r, g, b)
    return (h >= 335 || h <= 20) && s >= 0.16 && v >= 0.14 && r - g >= 12 && r - b >= 8
}

@inline(__always) func isWhitish(_ r: Int, _ g: Int, _ b: Int) -> Bool {
    let (_, s, v) = hsv(r, g, b)
    return s <= 0.30 && v >= 0.50
}

/// Кольцо: доля красного по окружности (16 лучей, полоса 0.7…1.0 радиуса),
/// середина (до 0.5 радиуса) — светлая и почти без красного.
func ringScore(_ im: RGBA, _ b: Blob) -> (Double, Double) {
    let cx = Double(b.minX + b.maxX) / 2, cy = Double(b.minY + b.maxY) / 2
    let rx = Double(b.w) / 2, ry = Double(b.h) / 2
    var hit = 0
    let rays = 24
    for k in 0..<rays {
        let a = Double(k) / Double(rays) * 2 * Double.pi
        var found = false
        var f = 0.62
        while f <= 1.05 && !found {
            let x = Int((cx + cos(a) * rx * f).rounded()), y = Int((cy + sin(a) * ry * f).rounded())
            if x >= 0 && y >= 0 && x < im.w && y < im.h && isShadedRed(im.r(x, y), im.g(x, y), im.b(x, y)) { found = true }
            f += 0.07
        }
        if found { hit += 1 }
    }
    var white = 0, red = 0, tot = 0
    let ix0 = Int(cx - rx * 0.5), ix1 = Int(cx + rx * 0.5)
    let iy0 = Int(cy - ry * 0.5), iy1 = Int(cy + ry * 0.5)
    if ix1 > ix0 && iy1 > iy0 {
        for y in max(0, iy0)...min(im.h - 1, iy1) {
            for x in max(0, ix0)...min(im.w - 1, ix1) {
                tot += 1
                let r = im.r(x, y), g = im.g(x, y), bb = im.b(x, y)
                if isRed(r, g, bb) { red += 1 } else if isWhitish(r, g, bb) { white += 1 }
                else {
                    // цифры тёмные — тоже «середина знака»
                    let (_, _, v) = hsv(r, g, bb)
                    if v < 0.35 { white += 1 }
                }
            }
        }
    }
    let ring = Double(hit) / Double(rays)
    let inner = tot > 0 ? Double(white) / Double(tot) - 2 * Double(red) / Double(tot) : 0
    return (ring, inner)
}

func cropScaled(_ cg: CGImage, _ rect: CGRect, minH: Int = 160) -> CGImage? {
    guard let c = cg.cropping(to: rect.integral) else { return nil }
    let scale = max(1.0, Double(minH) / Double(c.height))
    let w = Int(Double(c.width) * scale), h = Int(Double(c.height) * scale)
    // поля вокруг: Vision плохо читает текст, упёртый в край
    let pad = h / 4
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: w + 2 * pad, height: h + 2 * pad, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w + 2 * pad, height: h + 2 * pad))
    ctx.interpolationQuality = .high
    ctx.draw(c, in: CGRect(x: pad, y: pad, width: w, height: h))
    return ctx.makeImage()
}

func readNumber(_ cg: CGImage) -> (Int, Double)? {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = false
    req.customWords = ALLOWED.map { String($0) }
    req.minimumTextHeight = 0.1
    if DEBUG, let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "/tmp/claude_ocr_crop.png") as CFURL, "public.png" as CFString, 1, nil) {
        CGImageDestinationAddImage(dst, cg, nil); CGImageDestinationFinalize(dst)
    }
    do { try VNImageRequestHandler(cgImage: cg).perform([req]) } catch { dbg("  vision error \(error)"); return nil }
    dbg("  ocr results \(req.results?.count ?? -1)")
    var best: (Int, Double)? = nil
    for o in req.results ?? [] {
        dbg("  ocr: \(o.topCandidates(3).map { "\($0.string)/\($0.confidence)" })")
        for cand in o.topCandidates(3) {
            let digits = cand.string.filter { $0.isNumber }
            // O/o часто читаются вместо нуля — но только цифры из ряда
            let fixed = cand.string.replacingOccurrences(of: "O", with: "0")
                .replacingOccurrences(of: "o", with: "0").filter { $0.isNumber }
            for s in [digits, fixed] {
                if let v = Int(s), ALLOWED.contains(v), s.count == String(v).count {
                    let c = Double(cand.confidence)
                    if best == nil || c > best!.1 { best = (v, c) }
                }
            }
        }
    }
    return best
}

func detectSigns(_ im: RGBA, _ cg: CGImage) -> [Det] {
    let ylim = Int(Double(im.h) * SIGN_YLIM)
    var mask = [Bool](repeating: false, count: im.w * im.h)
    for y in 0..<ylim {
        for x in 0..<im.w where isShadedRed(im.r(x, y), im.g(x, y), im.b(x, y)) { mask[y * im.w + x] = true }
    }
    // Два шага расширения: тонкое кольцо маленького знака (20–30 px) на сжатом
    // кадре рвётся на куски. Сито кольца — мягкое: строгий затвор — число
    // из ряда 20…120, прочитанное в вырезке (OCR), без него сработки нет.
    mask = dilate(dilate(mask, im.w, ylim), im.w, ylim)
    var out: [Det] = []
    for b in components(mask, im.w, ylim) {
        let w = b.w, h = b.h
        if w < 8 || h < 8 || w > 220 || h > 220 { continue }
        let asp = Double(w) / Double(h)
        if asp < 0.5 || asp > 2.0 { continue }
        let fill = Double(b.n) / Double(w * h)
        if fill > 0.85 || fill < 0.15 { continue }
        let (ring, inner) = ringScore(im, b)
        dbg("ring cand \(b.minX),\(b.minY) \(w)x\(h) fill \(fill) ring \(ring) inner \(inner)")
        if ring < 0.45 || inner < -0.6 { continue }
        if ring >= 0.6 && inner >= 0.3 { RING_CANDS.append((b.minX, b.minY, w, h)) }
        // Кольцо на сжатом кадре часто рвётся, и рамка компоненты — только его
        // часть. Читаем три вырезки: середину рамки, квадрат по большей стороне
        // и тот же квадрат с полями; первая, где нашлось число из ряда, — ответ.
        let side = Double(max(w, h))
        let cxr = Double(b.minX) + Double(w) / 2, cyr = Double(b.minY) + Double(h) / 2
        let rect = CGRect(x: b.minX, y: b.minY, width: w, height: h)
        let bounds = CGRect(x: 0, y: 0, width: im.w, height: im.h)
        let crops = [rect.insetBy(dx: Double(w) * 0.12, dy: Double(h) * 0.12),
                     CGRect(x: cxr - side * 0.45, y: cyr - side * 0.45, width: side * 0.9, height: side * 0.9),
                     CGRect(x: cxr - side * 0.7, y: cyr - side * 0.7, width: side * 1.4, height: side * 1.4),
                     // кусок разорванного кольца: знак целиком — в окрестности побольше
                     CGRect(x: cxr - max(24, side * 1.5), y: cyr - max(24, side * 1.5),
                            width: max(48, side * 3), height: max(48, side * 3))]
        var found: (Int, Double)? = nil
        for r in crops {
            let rr = r.intersection(bounds)
            if rr.width < 4 || rr.height < 4 { continue }
            if let crop = cropScaled(cg, rr), let res = readNumber(crop) { found = res; break }
        }
        guard let (v, c) = found else { continue }
        let conf = min(1.0, 0.45 * ring + 0.25 * min(1, inner) + 0.3 * c)
        // Рамка знака — квадрат по большей стороне кольца (разорванное кольцо
        // даёт рамку меньше знака, а по размеру рамки оценивается расстояние).
        out.append(Det(cls: "speed_limit", value: v, x: cxr - side / 2, y: cyr - side / 2,
                       w: side, h: side, conf: conf))
    }
    return out
}

// MARK: - светофор

enum LampColor: String { case red, yellow, green }

@inline(__always) func lampColor(_ r: Int, _ g: Int, _ b: Int) -> LampColor? {
    let (h, s, v) = hsv(r, g, b)
    if (h >= 340 || h <= 16) && s >= 0.55 && v >= 0.62 { return .red }
    if h > 22 && h <= 52 && s >= 0.55 && v >= 0.72 { return .yellow }
    if h >= 125 && h <= 195 && s >= 0.40 && v >= 0.55 { return .green }
    return nil
}

/// Средняя яркость верхней части кадра: в тоннеле и под эстакадой темно, и
/// зелёные огни тоннеля и указатели выхода похожи на светофор — там не ищем.
func frameBrightness(_ im: RGBA) -> Double {
    var s = 0, n = 0
    for y in stride(from: 0, to: im.h / 2, by: 8) {
        for x in stride(from: 0, to: im.w, by: 8) {
            s += max(im.r(x, y), max(im.g(x, y), im.b(x, y))); n += 1
        }
    }
    return Double(s) / Double(max(n, 1)) / 255
}

func detectLights(_ im: RGBA) -> [Det] {
    let ylim = Int(Double(im.h) * LIGHT_YLIM)
    let fb = frameBrightness(im)
    dbg("frame brightness \(fb)")
    if fb < 0.22 { return [] }
    var cands: [(Blob, LampColor, Double)] = []
    for color in [LampColor.red, .yellow, .green] {
        var mask = [Bool](repeating: false, count: im.w * im.h)
        for y in 0..<ylim {
            for x in 0..<im.w where lampColor(im.r(x, y), im.g(x, y), im.b(x, y)) == color {
                mask[y * im.w + x] = true
            }
        }
        for b in components(mask, im.w, ylim, maxBlob: 3000) {
            let w = b.w, h = b.h
            if w < 3 || h < 3 || w > 36 || h > 36 { continue }
            let asp = Double(w) / Double(h)
            if asp < 0.6 || asp > 1.6 { continue }
            // Пятно с пересвеченной белой серединой: считаем и яркие пиксели в рамке.
            var lit = 0
            for y in b.minY...b.maxY {
                for x in b.minX...b.maxX {
                    let (_, s, v) = hsv(im.r(x, y), im.g(x, y), im.b(x, y))
                    if lampColor(im.r(x, y), im.g(x, y), im.b(x, y)) == color || (v > 0.9 && s < 0.35) { lit += 1 }
                }
            }
            let fill = Double(lit) / Double(w * h)
            if fill < 0.5 { continue }
            // Корпус: кольцо в пол-диаметра вокруг пятна — тёмное. Корпус секции
            // всего в ~1,6 раза шире линзы: кольцо шире захватывает небо по бокам,
            // и светофор на фоне неба не проходил.
            let d = max(w, h)
            let ring = max(2, d / 2)
            var dark = 0, bright = 0, tot = 0
            let x0 = max(0, b.minX - ring), x1 = min(im.w - 1, b.maxX + ring)
            let y0 = max(0, b.minY - ring), y1 = min(im.h - 1, b.maxY + ring)
            for y in y0...y1 {
                for x in x0...x1 {
                    if x >= b.minX - 1 && x <= b.maxX + 1 && y >= b.minY - 1 && y <= b.maxY + 1 { continue }
                    tot += 1
                    let (_, s, v) = hsv(im.r(x, y), im.g(x, y), im.b(x, y))
                    if v < 0.32 { dark += 1 }
                    if v > 0.93 && s < 0.15 { bright += 1 }
                }
            }
            if tot == 0 { continue }
            let darkShare = Double(dark) / Double(tot)
            // Солнце, небо, блик на стекле — вокруг светло, а не корпус.
            if Double(bright) / Double(tot) > 0.25 { continue }
            let low = b.cy > Double(im.h) * LOW_BAND
            if darkShare < (low ? 0.6 : 0.45) { continue }
            // Горящая секция светится: в пятне есть почти белые/предельно яркие пиксели.
            var vmax: Float = 0
            for y in b.minY...b.maxY { for x in b.minX...b.maxX {
                vmax = max(vmax, hsv(im.r(x, y), im.g(x, y), im.b(x, y)).2) } }
            // красная/жёлтая вывеска на солнце — до 0.9; горящая лампа пересвечена
            if vmax < (color == .green ? 0.86 : 0.95) { continue }
            // Корпус вертикальный: под красной / над зелёной секцией — тёмный столбец
            // ещё на 1–2 секции (вывески, LED-ленты и знак «главная дорога» так не умеют).
            func darkColumn(_ above: Bool) -> Double {
                let ya = above ? b.minY - Int(2.2 * Double(d)) : b.maxY + Int(0.4 * Double(d))
                let yb = above ? b.minY - Int(0.4 * Double(d)) : b.maxY + Int(2.2 * Double(d))
                var dk = 0, n = 0
                let y0 = max(0, ya), y1 = min(im.h - 1, max(ya, yb))
                if y1 < y0 { return 0 }   // секция у края кадра — столбца не видно
                for y in y0...y1 {
                    for x in max(0, b.minX)...min(im.w - 1, b.maxX) {
                        n += 1
                        if hsv(im.r(x, y), im.g(x, y), im.b(x, y)).2 < 0.35 { dk += 1 }
                    }
                }
                return n > 0 ? Double(dk) / Double(n) : 0
            }
            let below = darkColumn(false), above = darkColumn(true)
            let column: Double
            switch color {
            case .red: column = below
            case .green: column = above
            case .yellow: column = min(above, below)
            }
            dbg("light \(color) \(b.minX),\(b.minY) dark \(darkShare) column \(column) vmax \(vmax)")
            if column < 0.5 { continue }
            var conf = min(1.0, 0.25 + 0.35 * darkShare + 0.2 * fill + 0.2 * column)
            // жёлтый чаще всего — оранжевый знак «главная дорога» или вывеска
            if color == .yellow { conf *= 0.7 }
            cands.append((b, color, conf))
        }
    }
    // Задние фонари: пара одного цвета на одной высоте, одного размера, ниже горизонта.
    var drop = Set<Int>()
    for i in 0..<cands.count {
        for j in (i + 1)..<max(i + 1, cands.count) {
            let (a, ca, _) = cands[i], (b, cb, _) = cands[j]
            if ca != cb || ca == .green { continue }
            let d = Double(max(a.w, a.h, b.w, b.h))
            if abs(a.cy - b.cy) > max(2.5, 0.4 * d) { continue }
            let dx = abs(a.cx - b.cx)
            if dx < 3 * d || dx > 30 * d { continue }
            let ratio = Double(a.n) / Double(max(b.n, 1))
            if ratio < 0.4 || ratio > 2.5 { continue }
            if min(a.cy, b.cy) > Double(im.h) * (LOW_BAND - 0.05) { drop.insert(i); drop.insert(j) }
        }
    }
    var out: [Det] = []
    for (k, (b, c, conf)) in cands.enumerated() where !drop.contains(k) {
        out.append(Det(cls: "traffic_light", color: c.rawValue, x: Double(b.minX), y: Double(b.minY),
                       w: Double(b.w), h: Double(b.h), conf: conf))
    }
    return out
}

// MARK: - пешеходный переход (синий квадрат с белым треугольником)

/// Синий знака: и на солнце (0,80,200), и в тени (v ~0,2). Небо Ташкента
/// светлее (v > 0,85) или бледнее — его отсекают яркость и насыщенность.
@inline(__always) func isSignBlue(_ r: Int, _ g: Int, _ b: Int) -> Bool {
    let (h, s, v) = hsv(r, g, b)
    return h >= 195 && h <= 235 && s >= 0.55 && v >= 0.15 && v <= 0.85 && b - r >= 25
}

var DEBUG = false
var RING_CANDS: [(Int, Int, Int, Int)] = []
func dbg(_ s: String) { if DEBUG { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) } }

func detectCrossings(_ im: RGBA) -> [Det] {
    let ylim = Int(Double(im.h) * SIGN_YLIM)
    var mask = [Bool](repeating: false, count: im.w * im.h)
    for y in 0..<ylim {
        for x in 0..<im.w where isSignBlue(im.r(x, y), im.g(x, y), im.b(x, y)) { mask[y * im.w + x] = true }
    }
    var out: [Det] = []
    for b in components(mask, im.w, ylim) {
        let w = b.w, h = b.h
        if w < 10 || h < 10 || w > 160 || h > 160 { continue }
        let asp = Double(w) / Double(h)
        if asp < 0.75 || asp > 1.33 { continue }
        let fill = Double(b.n) / Double(w * h)
        dbg("crossing cand \(b.minX),\(b.minY) \(w)x\(h) fill \(fill)")
        if fill < 0.35 || fill > 0.88 { continue }
        // Средняя яркость синего — от неё считается «белый» (знак в тени тусклый).
        var vsum: Float = 0
        for y in b.minY...b.maxY { for x in b.minX...b.maxX where isSignBlue(im.r(x, y), im.g(x, y), im.b(x, y)) {
            vsum += hsv(im.r(x, y), im.g(x, y), im.b(x, y)).2 } }
        let vb = vsum / Float(max(b.n, 1))
        @inline(__always) func whiteOn(_ x: Int, _ y: Int) -> Bool {
            let (_, s, v) = hsv(im.r(x, y), im.g(x, y), im.b(x, y))
            return s <= 0.38 && v >= max(0.3, vb * 1.2)
        }
        // Углы квадрата синие (круглый синий знак здесь не пройдёт).
        let cw = max(2, w / 6), ch = max(2, h / 6)
        var cornerBlue = 0, cornerTot = 0
        for (ox, oy) in [(b.minX, b.minY), (b.maxX - cw + 1, b.minY), (b.minX, b.maxY - ch + 1),
                         (b.maxX - cw + 1, b.maxY - ch + 1)] {
            for y in oy..<(oy + ch) { for x in ox..<(ox + cw) {
                cornerTot += 1
                if isSignBlue(im.r(x, y), im.g(x, y), im.b(x, y)) { cornerBlue += 1 }
            } }
        }
        dbg("  corners \(Double(cornerBlue) / Double(cornerTot)) vb \(vb)")
        if Double(cornerBlue) / Double(cornerTot) < 0.3 { continue }
        // Белый треугольник вершиной вверх: белого в нижней трети шире, чем в верхней.
        func whiteRow(_ fy: Double) -> Int {
            let y = b.minY + Int(Double(h) * fy)
            var n = 0
            for x in b.minX...b.maxX where whiteOn(x, y) { n += 1 }
            return n
        }
        let top = whiteRow(0.3), mid = whiteRow(0.5), bot = whiteRow(0.72)
        let wTotal = Double(top + mid + bot) / Double(3 * w)
        dbg("  white rows \(top) \(mid) \(bot) share \(wTotal)")
        if wTotal < 0.12 || bot < 2 { continue }
        if !(Double(bot) >= Double(top) * 1.25 && Double(mid) >= Double(top) * 1.1) { continue }
        // Шаблон: внутри треугольника (вершина вверху, основание внизу) — не синее
        // (белый фон и тёмный пешеход), снаружи треугольника — синее.
        var inN = 0, inNon = 0, outN = 0, outBlue = 0
        for y in b.minY...b.maxY {
            let fy = (Double(y - b.minY) + 0.5) / Double(h)
            for x in b.minX...b.maxX {
                let fx = (Double(x - b.minX) + 0.5) / Double(w)
                let blue = isSignBlue(im.r(x, y), im.g(x, y), im.b(x, y))
                // треугольник: от (0.5, 0.12) до (0.1…0.9, 0.86); поле 0.06 не считаем
                let half = (fy - 0.12) / (0.86 - 0.12) * 0.4
                let dx = abs(fx - 0.5)
                if fy > 0.17 && fy < 0.82 && dx < half - 0.05 { inN += 1; if !blue { inNon += 1 } }
                else if fy < 0.06 || fy > 0.92 || dx > half + 0.07 { outN += 1; if blue { outBlue += 1 } }
            }
        }
        let tIn = Double(inNon) / Double(max(inN, 1)), tOut = Double(outBlue) / Double(max(outN, 1))
        dbg("  template in \(tIn) out \(tOut)")
        if tIn < 0.75 || tOut < 0.45 { continue }
        let conf = min(1.0, 0.2 + 0.4 * tIn + 0.4 * tOut)
        out.append(Det(cls: "crossing", x: Double(b.minX), y: Double(b.minY), w: Double(w), h: Double(h),
                       conf: conf))
    }
    return out
}

// MARK: - кандидаты всех дорожных знаков (для разметки кластерами)
//
// Не классификатор, а сито: форма и цвет, по которым знаки различимы издалека.
//   red_circle   — круг с красным кантом (запрещающие: стоянка/остановка, повороты, въезд…)
//   blue_circle  — синий круг (предписывающие: только прямо/направо…)
//   blue_square  — синий квадрат/прямоугольник (переход, одностороннее, полосы)
//   red_triangle — красный треугольник вершиной вверх (предупреждающие)
//   red_inverted — вершиной вниз («уступи дорогу»)
//   red_octagon  — сплошной красный с белым текстом (STOP)
//   yellow_diamond — «главная дорога»
// Фары, фонари и реклама отсекаются размером, долей заливки, белой/синей
// серединой и тем, что кант — контраст к середине, а не сплошная клякса.

struct SignCand: Encodable {
    let shape: String
    let x: Double, y: Double, w: Double, h: Double
    let score: Double
    var file: String? = nil
    var text: String? = nil      // только для табличек улиц/домов
    var value: Int? = nil        // число на круге с красным кантом (ограничение скорости)
}

/// Текст таблички улицы/дома. Читается ТОЛЬКО внутри синей таблички; номер
/// машины так не прочитать (он на белом), а Python-сторона ещё и отбрасывает
/// всё, похожее на номер.
func readPlate(_ cg: CGImage, _ c: SignCand) -> String? {
    let rect = CGRect(x: c.x, y: c.y, width: c.w, height: c.h).insetBy(dx: -2, dy: -2)
        .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    guard rect.width >= 8, rect.height >= 6, let crop = cropScaled(cg, rect, minH: 72) else { return nil }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    req.recognitionLanguages = ["ru-RU", "en-US"]
    do { try VNImageRequestHandler(cgImage: crop).perform([req]) } catch { return nil }
    let parts = (req.results ?? []).compactMap { o -> String? in
        guard let t = o.topCandidates(1).first, t.confidence >= 0.4 else { return nil }
        return t.string
    }
    let s = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    return s.count >= 2 ? s : nil
}

@inline(__always) func isOrange(_ r: Int, _ g: Int, _ b: Int) -> Bool {
    let (h, s, v) = hsv(r, g, b)
    // оранжевый знака — яркий и насыщенный; осенняя листва бледнее и темнее
    return h >= 24 && h <= 46 && s >= 0.72 && v >= 0.62
}

func maskOf(_ im: RGBA, _ ylim: Int, _ f: (Int, Int, Int) -> Bool) -> [Bool] {
    var m = [Bool](repeating: false, count: im.w * im.h)
    for y in 0..<ylim { for x in 0..<im.w where f(im.r(x, y), im.g(x, y), im.b(x, y)) { m[y * im.w + x] = true } }
    return m
}

/// Доля пикселей рамки, удовлетворяющих условию, в нормированной области [fx0,fx1]×[fy0,fy1].
func share(_ im: RGBA, _ b: Blob, _ fx0: Double, _ fx1: Double, _ fy0: Double, _ fy1: Double,
           _ f: (Int, Int, Int) -> Bool) -> Double {
    let x0 = b.minX + Int(Double(b.w) * fx0), x1 = b.minX + max(Int(Double(b.w) * fx1) - 1, 0)
    let y0 = b.minY + Int(Double(b.h) * fy0), y1 = b.minY + max(Int(Double(b.h) * fy1) - 1, 0)
    let ya = max(0, y0), yb = min(im.h - 1, y1), xa = max(0, x0), xb = min(im.w - 1, x1)
    if xb < xa || yb < ya { return 0 }
    var n = 0, k = 0
    for y in ya...yb { for x in xa...xb {
        n += 1; if f(im.r(x, y), im.g(x, y), im.b(x, y)) { k += 1 } } }
    return n > 0 ? Double(k) / Double(n) : 0
}

/// Ширина маски в строке fy (доля ширины рамки).
func rowWidth(_ mask: [Bool], _ w: Int, _ b: Blob, _ fy: Double) -> Double {
    let y = b.minY + min(b.h - 1, Int(Double(b.h) * fy))
    var lo = -1, hi = -1
    for x in b.minX...b.maxX where mask[y * w + x] { if lo < 0 { lo = x }; hi = x }
    return lo < 0 ? 0 : Double(hi - lo + 1) / Double(b.w)
}

/// Насыщенный красный краски знака (кирпич, листва и вывески в тени — бледнее).
@inline(__always) func isStrictRed(_ r: Int, _ g: Int, _ b: Int) -> Bool {
    let (h, s, v) = hsv(r, g, b)
    return (h >= 340 || h <= 12) && s >= 0.6 && v >= 0.45
}

/// Доля насыщенного красного в точках (нормированных к рамке), с допуском ±1 px.
func redEdges(_ im: RGBA, _ b: Blob, _ pts: [(Double, Double)], strict: Bool = true) -> Double {
    var hit = 0
    for (fx, fy) in pts {
        let x0 = b.minX + Int(Double(b.w - 1) * fx), y0 = b.minY + Int(Double(b.h - 1) * fy)
        var ok = false
        for dy in -1...1 { for dx in -1...1 {
            let x = x0 + dx, y = y0 + dy
            if x >= 0 && y >= 0 && x < im.w && y < im.h {
                let r = im.r(x, y), g = im.g(x, y), bl = im.b(x, y)
                if strict ? isStrictRed(r, g, bl) : isRed(r, g, bl) { ok = true }
            }
        } }
        if ok { hit += 1 }
    }
    return pts.isEmpty ? 0 : Double(hit) / Double(pts.count)
}

/// Точки на сторонах треугольника (вершиной вверх или вниз), с отступом от края.
func triEdges(up: Bool) -> [(Double, Double)] {
    var out: [(Double, Double)] = []
    let apexY = up ? 0.06 : 0.94, baseY = up ? 0.94 : 0.06
    for k in 1...5 {
        let t = Double(k) / 6
        out.append((0.5 - 0.44 * t, apexY + (baseY - apexY) * t))   // левая сторона
        out.append((0.5 + 0.44 * t, apexY + (baseY - apexY) * t))   // правая
        out.append((0.06 + 0.88 * t, baseY))                         // основание
    }
    return out
}

/// Круглый синий знак: на 0,8 радиуса — синее по всей окружности, на 1,15 —
/// не синее (белый кант / фон). Кусок стекла или неба так не выглядит.
func blueCircleScore(_ im: RGBA, _ b: Blob) -> Double {
    let cx = Double(b.minX + b.maxX) / 2, cy = Double(b.minY + b.maxY) / 2
    let rx = Double(b.w) / 2, ry = Double(b.h) / 2
    var inside = 0, outside = 0
    let rays = 24
    for k in 0..<rays {
        let a = Double(k) / Double(rays) * 2 * Double.pi
        let xi = Int(cx + cos(a) * rx * 0.8), yi = Int(cy + sin(a) * ry * 0.8)
        let xo = Int(cx + cos(a) * rx * 1.15), yo = Int(cy + sin(a) * ry * 1.15)
        if xi >= 0 && yi >= 0 && xi < im.w && yi < im.h && isSignBlue(im.r(xi, yi), im.g(xi, yi), im.b(xi, yi)) { inside += 1 }
        if xo < 0 || yo < 0 || xo >= im.w || yo >= im.h || !isSignBlue(im.r(xo, yo), im.g(xo, yo), im.b(xo, yo)) { outside += 1 }
    }
    return min(Double(inside), Double(outside)) / Double(rays)
}

func detectSignCandidates(_ im: RGBA) -> [SignCand] {
    if frameBrightness(im) < 0.22 { return [] }
    let ylim = Int(Double(im.h) * SIGN_YLIM)
    var out: [SignCand] = []
    let corners = { (im: RGBA, b: Blob, f: (Int, Int, Int) -> Bool) -> Double in
        (share(im, b, 0, 0.16, 0, 0.16, f) + share(im, b, 0.84, 1, 0, 0.16, f) +
         share(im, b, 0, 0.16, 0.84, 1, f) + share(im, b, 0.84, 1, 0.84, 1, f)) / 4 }
    // Знак на столбе (2–3 м) виден выше горизонта (камера на ~1,3 м);
    // задние фонари и кузова машин — на горизонте и ниже.
    let horizonY = Double(im.h) * (HORIZON + 0.01)
    // Синих фонарей у машин нет, а «объезд справа» стоит на островке низко —
    // синим разрешаем и чуть ниже горизонта.
    var yLimit = horizonY
    func ok(_ b: Blob, _ minS: Int = 10, _ maxS: Int = 170, _ aLo: Double = 0.7, _ aHi: Double = 1.4) -> Bool {
        let a = Double(b.w) / Double(b.h)
        return Double(b.minY + b.maxY) / 2 < yLimit && b.w >= minS && b.h >= minS && b.w <= maxS && b.h <= maxS && a >= aLo && a <= aHi
    }
    // красные
    var red = maskOf(im, ylim, isRed)
    red = dilate(red, im.w, ylim)
    for b in components(red, im.w, ylim) where ok(b) {
        let fill = Double(b.n) / Double(b.w * b.h)
        let centerWhite = share(im, b, 0.3, 0.7, 0.3, 0.7, isWhitish)
        let centerBlue = share(im, b, 0.3, 0.7, 0.3, 0.7, isSignBlue)
        let cornerRed = corners(im, b, isRed)
        let top = rowWidth(red, im.w, b, 0.12), bottom = rowWidth(red, im.w, b, 0.88)
        if fill >= 0.6 && centerWhite >= 0.08 && centerWhite <= 0.45 && cornerRed < 0.25 && b.w >= 14
            && redEdges(im, b, [(0.5, 0.04), (0.5, 0.96), (0.04, 0.5), (0.96, 0.5)]) >= 0.75
            && share(im, b, 0.1, 0.9, 0.1, 0.9, isStrictRed) >= 0.45 {
            // восьмиугольник: середины сторон красные, углы срезаны (вывеска — прямоугольник)
            out.append(SignCand(shape: "red_octagon", x: Double(b.minX), y: Double(b.minY), w: Double(b.w),
                                h: Double(b.h), score: centerWhite))
        } else if fill < 0.72 && fill > 0.18 && (centerWhite + centerBlue) >= 0.35 {
            if top < 0.45 && bottom > 0.75 && cornerRed < 0.35 && b.w >= 14 && centerWhite >= 0.3
                && redEdges(im, b, triEdges(up: true), strict: false) >= 0.7 {
                out.append(SignCand(shape: "red_triangle", x: Double(b.minX), y: Double(b.minY),
                                    w: Double(b.w), h: Double(b.h), score: bottom - top))
            } else if top > 0.75 && bottom < 0.45 && cornerRed < 0.35 && b.w >= 14 && centerWhite >= 0.3
                && redEdges(im, b, triEdges(up: false), strict: false) >= 0.7 {
                out.append(SignCand(shape: "red_inverted", x: Double(b.minX), y: Double(b.minY),
                                    w: Double(b.w), h: Double(b.h), score: top - bottom))
            } else if cornerRed < 0.2 && b.w >= 18 && b.h >= 18 && centerWhite + centerBlue >= 0.5 {
                // Знак: кант по всей окружности и белое (запрещающие) или синее
                // («остановка/стоянка запрещена») поле. Фасады и стёкла — нет.
                let (ring, _) = ringScore(im, b)
                if ring >= 0.7 {
                    out.append(SignCand(shape: "red_circle", x: Double(b.minX), y: Double(b.minY),
                                        w: Double(b.w), h: Double(b.h), score: ring))
                }
            }
        }
    }
    // синие
    yLimit = Double(im.h) * (HORIZON + 0.12)
    let blue = maskOf(im, ylim, isSignBlue)
    for b in components(blue, im.w, ylim) where ok(b, 10, 170, 0.5, 2.0) {
        let fill = Double(b.n) / Double(b.w * b.h)
        if fill < 0.4 || fill > 0.95 { continue }
        let white = share(im, b, 0.15, 0.85, 0.15, 0.85, isWhitish)
        if white < 0.06 || white > 0.6 { continue }   // знак — синее с белым символом
        let cb = corners(im, b, isSignBlue)
        let a = Double(b.w) / Double(b.h)
        let field = share(im, b, 0.12, 0.88, 0.12, 0.88, isSignBlue)
        if cb < 0.25 && a > 0.75 && a < 1.33 && fill < 0.85 && b.w >= 18 && b.h >= 18 && field >= 0.45
            && blueCircleScore(im, b) >= 0.7 {
            out.append(SignCand(shape: "blue_circle", x: Double(b.minX), y: Double(b.minY), w: Double(b.w),
                                h: Double(b.h), score: 1 - cb))
        } else if cb >= 0.45 {
            out.append(SignCand(shape: "blue_square", x: Double(b.minX), y: Double(b.minY), w: Double(b.w),
                                h: Double(b.h), score: cb))
        }
    }
    // Таблички улиц и домов: синий вытянутый прямоугольник с белым текстом.
    for b in components(blue, im.w, ylim) {
        let a = Double(b.w) / Double(b.h)
        if a < 1.8 || a > 6.5 || b.w < 24 || b.w > 320 || b.h < 8 || b.h > 90 { continue }
        if Double(b.minY + b.maxY) / 2 > Double(im.h) * (HORIZON + 0.12) { continue }
        let fill = Double(b.n) / Double(b.w * b.h)
        let white = share(im, b, 0.05, 0.95, 0.15, 0.85, isWhitish)
        if fill < 0.45 || white < 0.08 || white > 0.55 { continue }
        if corners(im, b, isSignBlue) < 0.4 { continue }
        out.append(SignCand(shape: "name_plate", x: Double(b.minX), y: Double(b.minY), w: Double(b.w),
                            h: Double(b.h), score: white))
    }
    // Конусы ремонта: красно-оранжевый узкий треугольник на дороге (ниже горизонта).
    let coneMask = maskOf(im, ylim) { r, g, b in
        let (h, s, v) = hsv(r, g, b); return h >= 6 && h <= 28 && s >= 0.65 && v >= 0.5 }
    for b in components(coneMask, im.w, ylim) {
        let a = Double(b.w) / Double(b.h)
        if a < 0.3 || a > 0.9 || b.h < 10 || b.h > 90 { continue }
        if Double(b.minY + b.maxY) / 2 < Double(im.h) * HORIZON { continue }
        let fill = Double(b.n) / Double(b.w * b.h)
        let top = rowWidth(coneMask, im.w, b, 0.15), bot = rowWidth(coneMask, im.w, b, 0.85)
        if fill < 0.3 || fill > 0.75 || bot < top * 1.4 { continue }
        out.append(SignCand(shape: "orange_cone", x: Double(b.minX), y: Double(b.minY), w: Double(b.w),
                            h: Double(b.h), score: bot - top))
    }
    // «главная дорога»: оранжевый ромб — заливка ~половина рамки, углы пустые
    yLimit = horizonY
    let orange = maskOf(im, ylim, isOrange)
    for b in components(orange, im.w, ylim) where ok(b, 9, 120, 0.75, 1.33) {
        let fill = Double(b.n) / Double(b.w * b.h)
        let co = corners(im, b, isOrange)
        let mid = rowWidth(orange, im.w, b, 0.5), top = rowWidth(orange, im.w, b, 0.12)
        let solid = share(im, b, 0.35, 0.65, 0.35, 0.65, isOrange)
        if fill > 0.35 && fill < 0.7 && co < 0.12 && mid > 0.7 && top < 0.4 && solid > 0.85 {
            out.append(SignCand(shape: "yellow_diamond", x: Double(b.minX), y: Double(b.minY),
                                w: Double(b.w), h: Double(b.h), score: mid - top))
        }
    }
    return out
}

/// Число в круге с красным кантом: середина круга (без канта), апскейл ×3+.
func readCircleNumber(_ cg: CGImage, _ c: SignCand) -> Int? {
    let side = max(c.w, c.h)
    let cx = c.x + c.w / 2, cy = c.y + c.h / 2
    let bounds = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
    for k in [0.36, 0.45, 0.6] {
        let r = CGRect(x: cx - side * k, y: cy - side * k, width: side * 2 * k, height: side * 2 * k)
            .intersection(bounds)
        if r.width < 6 || r.height < 6 { continue }
        if let crop = cropScaled(cg, r, minH: max(96, Int(r.height * 3))), let (v, _) = readNumber(crop) { return v }
    }
    return nil
}

func writeSignCrop(_ cg: CGImage, _ c: SignCand, _ path: String) -> Bool {
    let side = max(c.w, c.h) * 1.3
    let rect = CGRect(x: c.x + c.w / 2 - side / 2, y: c.y + c.h / 2 - side / 2, width: side, height: side)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: 96, height: 96, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
    ctx.interpolationQuality = .high
    // CGContext — снизу вверх: кадр рисуем целиком со сдвигом и масштабом
    let k = 96.0 / side
    let H = Double(cg.height)
    ctx.draw(cg, in: CGRect(x: -rect.minX * k, y: -(H - rect.maxY) * k, width: Double(cg.width) * k, height: H * k))
    guard let img = ctx.makeImage(),
          let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.jpeg" as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    return CGImageDestinationFinalize(dst)
}

// MARK: - вырезки с размытием

struct CropSpec: Decodable { let src: String; let dst: String; let box: [Double]; let keep: [Double]? }

func makeCrop(_ spec: CropSpec, _ ci: CIContext) throws {
    guard let cg = loadCG(spec.src) else { throw NSError(domain: "crop", code: 1) }
    let H = Double(cg.height)
    // Vision: лица и строки текста (номера машин) по всему кадру
    let faces = VNDetectFaceRectanglesRequest()
    let text = VNDetectTextRectanglesRequest()
    try VNImageRequestHandler(cgImage: cg).perform([faces, text])
    var rects: [CGRect] = []
    let W = Double(cg.width)
    for o in (faces.results ?? []) as [VNDetectedObjectObservation] + (text.results ?? []) {
        let bb = o.boundingBox
        // Vision — снизу вверх, нормировано; переводим в CI-координаты (тоже снизу вверх)
        rects.append(CGRect(x: bb.minX * W, y: bb.minY * H, width: bb.width * W, height: bb.height * H)
            .insetBy(dx: -4, dy: -4))
    }
    var img = CIImage(cgImage: cg)
    let keep: CGRect? = spec.keep.map { CGRect(x: $0[0], y: H - $0[1] - $0[3], width: $0[2], height: $0[3]) }
    let blurred = img.clampedToExtent().applyingGaussianBlur(sigma: 10).cropped(to: img.extent)
    for r in rects {
        // Число на самом знаке — не номер машины, его не размываем.
        if let k = keep, k.insetBy(dx: -2, dy: -2).contains(r) { continue }
        img = blurred.cropped(to: r).composited(over: img)
    }
    let b = spec.box
    let cropRect = CGRect(x: b[0], y: H - b[1] - b[3], width: b[2], height: b[3]).intersection(img.extent)
    var out = img.cropped(to: cropRect)
    let scale = max(1.0, 240.0 / cropRect.height)
    out = out.transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let cs = CGColorSpaceCreateDeviceRGB()
    try ci.writeJPEGRepresentation(of: out, to: URL(fileURLWithPath: spec.dst), colorSpace: cs,
                                   options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85])
}

// MARK: - main

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: detect detect LIST | detect crop SPEC\n".data(using: .utf8)!)
    exit(2)
}
let enc = JSONEncoder()
if args[1] == "detect" {
    let list = try String(contentsOfFile: args[2], encoding: .utf8).split(separator: "\n").map(String.init)
    for path in list where !path.isEmpty {
        autoreleasepool {
            guard let cg = loadCG(path) else {
                print("{\"f\":\(String(data: try! enc.encode(path), encoding: .utf8)!),\"err\":\"read\"}")
                return
            }
            let im = rgba(cg)
            var dets = detectSigns(im, cg)
            dets += detectLights(im)
            dets += detectCrossings(im)
            if ProcessInfo.processInfo.environment["RINGS"] != nil {
                for (x, y, w, h) in RING_CANDS where !dets.contains(where: { $0.cls == "speed_limit" && abs($0.x + $0.w / 2 - Double(x) - Double(w) / 2) < 2 && abs($0.y + $0.h / 2 - Double(y) - Double(h) / 2) < 2 }) {
                    dets.append(Det(cls: "red_ring", x: Double(x), y: Double(y), w: Double(w), h: Double(h), conf: 0))
                }
            }
            RING_CANDS.removeAll()
            // Кандидаты знаков: вырезки 96×96 пишутся сразу, пока кадр в памяти.
            var signs: [SignCand] = []
            if let dir = ProcessInfo.processInfo.environment["SIGN_DIR"] {
                let stem = (path as NSString).lastPathComponent.replacingOccurrences(of: ".jpg", with: "")
                let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                for (k, var c) in detectSignCandidates(im).enumerated() {
                    if c.shape == "name_plate" {
                        // табличка без прочитанного текста — почти всегда кусок неба/фасада
                        c.text = readPlate(cg, c)
                        if c.text == nil { continue }
                    }
                    if c.shape == "red_circle" { c.value = readCircleNumber(cg, c) }
                    let sub = dir + "/" + c.shape
                    try? FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
                    let file = sub + "/" + parent + "_" + stem + "_\(k).jpg"
                    if writeSignCrop(cg, c, file) { c.file = file }
                    signs.append(c)
                }
            }
            struct Line: Encodable { let f: String; let d: [Det]; let s: [SignCand] }
            print(String(data: try! enc.encode(Line(f: path, d: dets, s: signs)), encoding: .utf8)!)
            fflush(stdout)
        }
    }
} else if args[1] == "textscan" {
    // Текст сначала: числа из ряда 20…120 по всему верху кадра (медленно — для
    // поиска эталонных кадров и проверки полноты кандидатов). Текст не выводится.
    let list = try String(contentsOfFile: args[2], encoding: .utf8).split(separator: "\n").map(String.init)
    for path in list where !path.isEmpty {
        autoreleasepool {
            guard let cg = loadCG(path) else { return }
            let im0 = rgba(cg)
            // Плитки 400×280 с перекрытием, апскейл ×2.5: целый кадр Vision
            // уменьшает, и цифры знака (12–20 px) пропадают.
            let ylim = Int(Double(cg.height) * SIGN_YLIM)
            var seen = Set<String>()
            for ty in stride(from: 0, to: max(1, ylim - 140), by: 200) {
                for tx in stride(from: 0, to: cg.width - 200, by: 300) {
                    let tile = CGRect(x: tx, y: ty, width: min(400, cg.width - tx), height: min(280, ylim - ty))
                    guard let crop = cropScaled(cg, tile, minH: 700) else { continue }
                    let req = VNRecognizeTextRequest()
                    req.recognitionLevel = .accurate
                    req.usesLanguageCorrection = false
                    try? VNImageRequestHandler(cgImage: crop).perform([req])
                    for o in req.results ?? [] {
                        guard let c = o.topCandidates(1).first else { continue }
                        let digits = c.string.filter { $0.isNumber }
                        guard let v = Int(digits), ALLOWED.contains(v), digits.count == c.string.count else { continue }
                        // рамка Vision — в вырезке с полями (pad = h/4 у cropScaled)
                        let W = Double(crop.width), H = Double(crop.height)
                        let pad = (H / 1.5) / 4
                        let sc = (H - 2 * pad) / tile.height
                        let bx = (o.boundingBox.minX * W - pad) / sc + tile.minX
                        let by = ((1 - o.boundingBox.maxY) * H - pad) / sc + tile.minY
                        let key = "\(v)_\(Int(bx / 20))_\(Int(by / 20))"
                        if seen.contains(key) { continue }
                        seen.insert(key)
                        let bw = o.boundingBox.width * W / sc, bh = o.boundingBox.height * H / sc
                        // Кант вокруг цифр: круг радиусом ~1,1 ширины числа — доля лучей с красным.
                        let side = max(bw, bh) * 2.1
                        let blob = Blob(minX: Int(bx + bw / 2 - side / 2), minY: Int(by + bh / 2 - side / 2),
                                        maxX: Int(bx + bw / 2 + side / 2), maxY: Int(by + bh / 2 + side / 2), n: 1)
                        let ring = (blob.minX >= 0 && blob.minY >= 0 && blob.maxX < im0.w && blob.maxY < im0.h)
                            ? ringScore(im0, blob).0 : 0
                        print("\(path)\t\(v)\t\(Int(bx))\t\(Int(by))\t\(Int(bw))\t\(Int(bh))\t\(String(format: "%.2f", ring))")
                    }
                }
            }
            fflush(stdout)
        }
    }
} else if args[1] == "debug" {
    DEBUG = true
    if let cg = loadCG(args[2]) {
        let im = rgba(cg)
        let d = detectSigns(im, cg) + detectLights(im) + detectCrossings(im)
        print(String(data: try! enc.encode(d), encoding: .utf8)!)
        print(String(data: try! enc.encode(detectSignCandidates(im)), encoding: .utf8)!)
    }
} else if args[1] == "crop" {
    let ci = CIContext()
    let lines = try String(contentsOfFile: args[2], encoding: .utf8).split(separator: "\n")
    for l in lines {
        do {
            let spec = try JSONDecoder().decode(CropSpec.self, from: Data(l.utf8))
            try makeCrop(spec, ci)
            print("ok \(spec.dst)")
        } catch {
            print("err \(error)")
        }
    }
}
