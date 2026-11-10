import AppKit
import CoreImage
import Foundation
import SceneKit

// MARK: - Материалы

struct RGB { var r, g, b: Double
    var color: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

enum Mat {
    static func pbr(_ c: RGB, metal: Double, rough: Double, coat: Double = 0, coatRough: Double = 0.04,
                    emission: RGB? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = c.color
        m.metalness.contents = NSNumber(value: metal)
        m.roughness.contents = NSNumber(value: rough)
        if coat > 0 {
            m.clearCoat.contents = NSNumber(value: coat)
            m.clearCoatRoughness.contents = NSNumber(value: coatRough)
        }
        if let e = emission { m.emission.contents = e.color }
        m.isDoubleSided = true
        return m
    }
    /// Лак: металлик с прозрачным слоем — блик поверх цвета.
    static func paint(_ c: RGB, metal: Double = 0.55, rough: Double = 0.32) -> SCNMaterial {
        pbr(c, metal: metal, rough: rough, coat: 1, coatRough: 0.03)
    }
    static let glass = pbr(RGB(r: 0.30, g: 0.38, b: 0.50), metal: 0.45, rough: 0.05, coat: 1, coatRough: 0.0)
    static let tint = pbr(RGB(r: 0.16, g: 0.20, b: 0.27), metal: 0.4, rough: 0.06, coat: 1, coatRough: 0.0)
    static let chrome = pbr(RGB(r: 0.93, g: 0.94, b: 0.96), metal: 1, rough: 0.1)
    static let satin = pbr(RGB(r: 0.62, g: 0.64, b: 0.67), metal: 1, rough: 0.32)
    static let rubber = pbr(RGB(r: 0.035, g: 0.035, b: 0.04), metal: 0, rough: 0.85)
    static let trim = pbr(RGB(r: 0.05, g: 0.055, b: 0.06), metal: 0, rough: 0.5)
    static let gloss = pbr(RGB(r: 0.03, g: 0.03, b: 0.035), metal: 0.2, rough: 0.18, coat: 1)
}

// MARK: - Окружение: процедурная студия, свет слева сверху

/// Равнопромежуточная карта: u 0 — справа экрана, 0,25 — сзади, 0,5 — слева,
/// 0,75 — спереди (нос); верх картинки — зенит (проверено зеркальным шаром).
func studioEnvironment() -> CGImage {
    let w = 1024, h = 512
    var px = [UInt8](repeating: 0, count: w * h * 4)
    func lobe(_ u: Double, _ v: Double, cu: Double, cv: Double, su: Double, sv: Double) -> Double {
        var du = abs(u - cu); du = min(du, 1 - du)
        let a = du / su, b = (v - cv) / sv
        let d = pow(pow(abs(a), 4) + pow(abs(b), 4), 0.25)   // мягкий прямоугольник
        return clamp01(1.4 - d * 1.4)
    }
    for y in 0..<h {
        let v = (Double(y) + 0.5) / Double(h)            // 0 — зенит, 1 — надир
        let elev = (0.5 - v) * 180                         // градусы
        for x in 0..<w {
            let u = (Double(x) + 0.5) / Double(w)
            let side = cos((u - 0.5) * 2 * .pi)          // +1 слева, −1 справа
            let front = cos((u - 0.75) * 2 * .pi)        // +1 спереди, −1 сзади
            var l: Double
            if elev > 0 {
                // Студия: тёмные стены, свет сверху, сильнее слева.
                let hi = smooth((elev - 35) / 40)
                l = 0.025 + hi * (0.20 + 0.18 * side)
            } else {
                l = 0.06 * (1 - smooth(-elev / 25)) + 0.03
            }
            var r = l, g = l, b = l * 1.03
            // Софтбокс вверху слева — длинный блик по левым скатам.
            let box = lobe(u, v, cu: 0.52, cv: 0.17, su: 0.09, sv: 0.10)
                + 0.8 * lobe(u, v, cu: 0.55, cv: 0.075, su: 0.16, sv: 0.045)
            // Узкая полоса слева пониже — кант блика на левом борту.
            let strip = lobe(u, v, cu: 0.5, cv: 0.36, su: 0.025, sv: 0.10)
                + 0.55 * lobe(u, v, cu: 0.5, cv: 0.47, su: 0.07, sv: 0.09)
            // Небо впереди (лобовое отражает его) и тусклее сзади (заднее стекло).
            let skyBand = smooth((elev - 6) / 8) * (1 - smooth((elev - 30) / 30))
            let skyF = skyBand * max(0, front) * 0.75
                + 0.9 * lobe(u, v, cu: 0.68, cv: 0.33, su: 0.018, sv: 0.10)
            let skyR = skyBand * max(0, -front) * 0.22
            r += 0.95 * box + 0.7 * strip + skyF * 0.80 + skyR * 0.8
            g += 0.95 * box + 0.7 * strip + skyF * 0.88 + skyR * 0.88
            b += 0.95 * box + 0.7 * strip + skyF * 1.00 + skyR * 1.0
            let i = (y * w + x) * 4
            px[i] = UInt8(min(1, r) * 255); px[i + 1] = UInt8(min(1, g) * 255)
            px[i + 2] = UInt8(min(1, b) * 255); px[i + 3] = 255
        }
    }
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx.makeImage()!
}

// MARK: - Рендер

struct Vehicle {
    let id: String
    let title: String
    /// Длина значка, пункты.
    let lengthPt: Double
    /// Длина модели, метры.
    let lengthM: Double
    let build: () -> SCNNode
}

/// Холст значка в пунктах (с полями под тень и ободок).
let canvasPt = CGSize(width: 44, height: 60)
/// Белый ободок и мягкая контактная тень, пункты.
let rimPt = 1.25, shadowGrowPt = 0.7, shadowBlurPt = 2.2, shadowAlpha = 0.5

let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

/// Рендер модели сверху: px на пункт задаёт масштаб, перспектива лёгкая.
func renderRaw(_ v: Vehicle, pxPerPt: Double) -> CGImage {
    let scene = SCNScene()
    scene.background.contents = NSColor.clear
    scene.lightingEnvironment.contents = studioEnvironment()
    scene.lightingEnvironment.intensity = 2.6
    scene.rootNode.addChildNode(v.build())

    let key = SCNNode()
    key.light = SCNLight()
    key.light!.type = .directional
    key.light!.intensity = 700
    key.light!.color = NSColor(white: 1, alpha: 1)
    // Свет слева-сверху-спереди экрана (−x, вверх, к носу −z сцены).
    key.position = SCNVector3(-6, 11, -4)
    key.look(at: SCNVector3(0, 0, 0))
    scene.rootNode.addChildNode(key)

    let ppm = v.lengthPt / v.lengthM                  // пунктов на метр
    let height = 16.0                                   // камера над землёй, м
    let refZ = 0.7                                      // плоскость точного масштаба
    let viewH = Double(canvasPt.height) / ppm
    let cam = SCNNode()
    cam.camera = SCNCamera()
    cam.camera!.fieldOfView = CGFloat(2 * atan(viewH / 2 / (height - refZ)) * 180 / .pi)
    cam.camera!.projectionDirection = .vertical
    cam.camera!.zNear = 1; cam.camera!.zFar = 40
    cam.camera!.wantsHDR = false
    cam.camera!.screenSpaceAmbientOcclusionIntensity = 0.8
    cam.camera!.screenSpaceAmbientOcclusionRadius = 0.25
    cam.position = SCNVector3(0, height, 0)
    cam.eulerAngles = SCNVector3(-Double.pi / 2, 0, 0)
    scene.rootNode.addChildNode(cam)

    let r = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
    r.scene = scene
    r.pointOfView = cam
    let size = CGSize(width: canvasPt.width * pxPerPt, height: canvasPt.height * pxPerPt)
    let img = r.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    return img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
}

/// Ободок и тень по альфе рендера — без сдвига, симметрично.
func finish(_ raw: CGImage, pxPerPt: Double) -> CGImage {
    let src = CIImage(cgImage: raw)
    let mask = src.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    let rim = mask.applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": rimPt * pxPerPt])
        .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 0.25 * pxPerPt]).cropped(to: src.extent)
        .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.97),
                                                     "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0.97),
                                                     "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0.97),
                                                     "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0.97)])
    let shadow = mask.applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": (rimPt + shadowGrowPt) * pxPerPt])
        .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": shadowBlurPt * pxPerPt]).cropped(to: src.extent)
        .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: shadowAlpha)])
    let out = src.composited(over: rim.composited(over: shadow))
    return ciContext.createCGImage(out, from: src.extent, format: .RGBA8,
                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
}

/// Уменьшение с высоким качеством (премультиплицированная альфа).
func downscale(_ img: CGImage, to size: CGSize) -> CGImage {
    var cur = img
    // Ступенями по ≤2×: сглаживает тонкие блики без мерцания.
    while Double(cur.width) > Double(size.width) * 2.01 {
        let w = Int((Double(cur.width) / 2).rounded()), h = Int((Double(cur.height) / 2).rounded())
        cur = drawScaled(cur, w, h)
    }
    return drawScaled(cur, Int(size.width), Int(size.height))
}

func drawScaled(_ img: CGImage, _ w: Int, _ h: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func loadPNG(_ path: String) -> CGImage {
    let data = try! Data(contentsOf: URL(fileURLWithPath: path))
    return NSBitmapImageRep(data: data)!.cgImage!
}
