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
let HORIZON: Double = 0.55            // примерно горизонт в кадре детекторов

@inline(__always) func isRed(_ r: Int, _ g: Int, _ b: Int) -> Bool {
    let (h, s, v) = hsv(r, g, b)
    // Тонкое кольцо на сжатом кадре размыто цветностью JPEG: красный уходит в
    // розовый (с белым) и в пурпур (с синим), насыщенность падает до ~0.3.
    return (h >= 318 || h <= 20) && s >= 0.28 && v >= 0.25
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
            if x >= 0 && y >= 0 && x < im.w && y < im.h && isRed(im.r(x, y), im.g(x, y), im.b(x, y)) { found = true }
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
        for x in 0..<im.w where isRed(im.r(x, y), im.g(x, y), im.b(x, y)) { mask[y * im.w + x] = true }
    }
    mask = dilate(mask, im.w, ylim)
    var out: [Det] = []
    for b in components(mask, im.w, ylim) {
        let w = b.w, h = b.h
        if w < 9 || h < 9 || w > 220 || h > 220 { continue }
        let asp = Double(w) / Double(h)
        if asp < 0.6 || asp > 1.55 { continue }
        let fill = Double(b.n) / Double(w * h)
        if fill > 0.75 || fill < 0.15 { continue }
        let (ring, inner) = ringScore(im, b)
        dbg("ring cand \(b.minX),\(b.minY) \(w)x\(h) fill \(fill) ring \(ring) inner \(inner)")
        if ring < 0.6 || inner < 0.3 { continue }
        RING_CANDS.append((b.minX, b.minY, w, h))
        // Кольцо на сжатом кадре часто рвётся, и рамка компоненты — только его
        // часть. Читаем три вырезки: середину рамки, квадрат по большей стороне
        // и тот же квадрат с полями; первая, где нашлось число из ряда, — ответ.
        let side = Double(max(w, h))
        let cxr = Double(b.minX) + Double(w) / 2, cyr = Double(b.minY) + Double(h) / 2
        let rect = CGRect(x: b.minX, y: b.minY, width: w, height: h)
        let bounds = CGRect(x: 0, y: 0, width: im.w, height: im.h)
        let crops = [rect.insetBy(dx: Double(w) * 0.12, dy: Double(h) * 0.12),
                     CGRect(x: cxr - side * 0.45, y: cyr - side * 0.45, width: side * 0.9, height: side * 0.9),
                     CGRect(x: cxr - side * 0.7, y: cyr - side * 0.7, width: side * 1.4, height: side * 1.4)]
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

func detectLights(_ im: RGBA) -> [Det] {
    let ylim = Int(Double(im.h) * LIGHT_YLIM)
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
            // Корпус: кольцо шириной в диаметр вокруг пятна — тёмное.
            let d = max(w, h)
            var dark = 0, bright = 0, tot = 0
            let x0 = max(0, b.minX - d), x1 = min(im.w - 1, b.maxX + d)
            let y0 = max(0, b.minY - d), y1 = min(im.h - 1, b.maxY + d)
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
            let low = b.cy > Double(im.h) * HORIZON
            if darkShare < (low ? 0.6 : 0.45) { continue }
            let conf = min(1.0, 0.35 + 0.45 * darkShare + 0.2 * fill)
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
            if min(a.cy, b.cy) > Double(im.h) * (HORIZON - 0.05) { drop.insert(i); drop.insert(j) }
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
            struct Line: Encodable { let f: String; let d: [Det] }
            print(String(data: try! enc.encode(Line(f: path, d: dets)), encoding: .utf8)!)
            fflush(stdout)
        }
    }
} else if args[1] == "debug" {
    DEBUG = true
    if let cg = loadCG(args[2]) {
        let im = rgba(cg)
        let d = detectSigns(im, cg) + detectLights(im) + detectCrossings(im)
        print(String(data: try! enc.encode(d), encoding: .utf8)!)
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
