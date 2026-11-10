import AppKit
import Foundation
import SceneKit

/// Рисунок по плану машины (вид сверху, метры) в каналы PBR: цвет, свечение,
/// металл, шероховатость. Наносится проекцией сверху — ровно так, как его
/// видит камера значка, поэтому контуры фар и полос гладкие при любом размере.
final class Livery {
    static let span = 7.0          // метров на сторону текстуры
    static let px = 2048
    nonisolated(unsafe) static var dumpCount = 0

    let diffuse: CGContext, emission: CGContext, metal: CGContext, rough: CGContext

    init(base: RGB, metal m: Double, rough r: Double) {
        func ctx(_ gray: Bool) -> CGContext {
            CGContext(data: nil, width: Livery.px, height: Livery.px, bitsPerComponent: 8, bytesPerRow: 0,
                      space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
        }
        diffuse = ctx(false); emission = ctx(false); metal = ctx(true); rough = ctx(true)
        let all = CGRect(x: 0, y: 0, width: Livery.px, height: Livery.px)
        diffuse.setFillColor(base.color.cgColor); diffuse.fill(all)
        emission.setFillColor(CGColor(gray: 0, alpha: 1)); emission.fill(all)
        metal.setFillColor(CGColor(gray: m, alpha: 1)); metal.fill(all)
        rough.setFillColor(CGColor(gray: r, alpha: 1)); rough.fill(all)
        let k = Double(Livery.px) / Livery.span
        for c in [diffuse, emission, metal, rough] {
            c.translateBy(x: CGFloat(Livery.px) / 2, y: CGFloat(Livery.px) / 2)
            c.scaleBy(x: k, y: k)
            c.setShouldAntialias(true)
            c.interpolationQuality = .high
        }
    }

    struct Ink {
        var color: RGB? = nil
        var glow: RGB? = nil
        var metal: Double? = nil
        var rough: Double? = nil
    }

    func fill(_ path: CGPath, _ ink: Ink, mirror: Bool = false) {
        var paths = [path]
        if mirror {
            var t = CGAffineTransform(scaleX: -1, y: 1)
            if let m = path.copy(using: &t) { paths.append(m) }
        }
        for p in paths {
            if let c = ink.color { diffuse.addPath(p); diffuse.setFillColor(c.color.cgColor); diffuse.fillPath() }
            if let g = ink.glow { emission.addPath(p); emission.setFillColor(g.color.cgColor); emission.fillPath() }
            if let m = ink.metal { metal.addPath(p); metal.setFillColor(CGColor(gray: m, alpha: 1)); metal.fillPath() }
            if let r = ink.rough { rough.addPath(p); rough.setFillColor(CGColor(gray: r, alpha: 1)); rough.fillPath() }
        }
    }

    func stroke(_ path: CGPath, width: Double, _ ink: Ink, mirror: Bool = false) {
        fill(path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 4), ink, mirror: mirror)
    }

    /// Мягкое пятно цвета (градиент), например отражение неба на стекле.
    func gradient(_ path: CGPath, from a: (CGPoint, RGB), to b: (CGPoint, RGB)) {
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [a.1.color.cgColor, b.1.color.cgColor] as CFArray, locations: [0, 1])!
        diffuse.saveGState(); diffuse.addPath(path); diffuse.clip()
        diffuse.drawLinearGradient(g, start: a.0, end: b.0, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        diffuse.restoreGState()
    }

    /// Мягкое круглое пятно света на цвете (отсвет неба), края без резкой границы.
    func glow(center: CGPoint, radius: Double, color: RGB, alpha: Double) {
        let c0 = color.color.withAlphaComponent(alpha).cgColor, c1 = color.color.withAlphaComponent(0).cgColor
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [c0, c1] as CFArray, locations: [0, 1])!
        diffuse.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    func material(coat: Double = 1, coatRough: Double = 0.03) -> SCNMaterial {
        if let dir = ProcessInfo.processInfo.environment["CURSOR_LIVERY"] {
            Livery.dumpCount += 1
            writePNG(diffuse.makeImage()!, "\(dir)/livery\(Livery.dumpCount).png")
        }
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = diffuse.makeImage()
        m.emission.contents = emission.makeImage()
        m.metalness.contents = metal.makeImage()
        m.roughness.contents = rough.makeImage()
        for p in [m.diffuse, m.emission, m.metalness, m.roughness] {
            p.mipFilter = .linear; p.minificationFilter = .linear; p.magnificationFilter = .linear
            p.wrapS = .clamp; p.wrapT = .clamp
        }
        if coat > 0 {
            m.clearCoat.contents = NSNumber(value: coat)
            m.clearCoatRoughness.contents = NSNumber(value: coatRough)
        }
        m.isDoubleSided = true
        return m
    }
}

/// Контур по функции края: внешняя граница — край плюс вылет, внутренняя — глубже на depth(x).
func edgeBand(x0: Double, x1: Double, edge: (Double) -> Double, depth: (Double) -> Double,
              overshoot: Double = 0.06, front: Bool = true, steps: Int = 40) -> CGPath {
    let p = CGMutablePath()
    let s = front ? 1.0 : -1.0
    for i in 0...steps {
        let x = lerp(x0, x1, Double(i) / Double(steps))
        let pt = CGPoint(x: x, y: edge(x) + s * overshoot)
        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    for i in (0...steps).reversed() {
        let x = lerp(x0, x1, Double(i) / Double(steps))
        p.addLine(to: CGPoint(x: x, y: edge(x) - s * depth(x)))
    }
    p.closeSubpath()
    return p
}

func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, r: Double = 0) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: min(r, w / 2), cornerHeight: min(r, h / 2), transform: nil)
}
