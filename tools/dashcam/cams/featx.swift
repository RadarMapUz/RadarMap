// Векторы Vision FeaturePrint по участкам верхней части кадра.
//
//   featx LIST OUT.f32 [fine]
//
// fine — мелкая сетка: 9×3 плитки 256×190 с шагом 128×95 по полосе 1280×380
// (камера на консоли — 20–40 px; на плитке она остаётся заметной).
//
// LIST — пути JPEG (кадры детекторов 1280×529). Для каждого кадра — R участков
// (REGIONS ниже, в пикселях JPEG): вся полоса над горизонтом и три
// перекрывающиеся плитки — камера на консоли мелкая, и на целой полосе после
// сжатия до входа сети её почти не остаётся. OUT — float32 подряд:
// кадр × участок × размер вектора. Нечитаемый кадр — нули.
// Размер вектора печатается в stderr («dim N»).
import CoreGraphics
import Foundation
import ImageIO
import Vision

let COARSE: [CGRect] = [
    CGRect(x: 0, y: 0, width: 1280, height: 380),
    CGRect(x: 0, y: 0, width: 560, height: 380),
    CGRect(x: 360, y: 0, width: 560, height: 380),
    CGRect(x: 720, y: 0, width: 560, height: 380),
]

let args = CommandLine.arguments
guard args.count == 3 || args.count == 4 else {
    FileHandle.standardError.write("usage: featx LIST OUT.f32 [fine]\n".data(using: .utf8)!)
    exit(2)
}
var FINE: [CGRect] = []
for row in 0..<3 {
    for col in 0..<9 {
        FINE.append(CGRect(x: col * 128, y: row * 95, width: 256, height: 190))
    }
}
let REGIONS = args.count == 4 && args[3] == "fine" ? FINE : COARSE
let list = try String(contentsOfFile: args[1], encoding: .utf8).split(separator: "\n").map(String.init)
FileManager.default.createFile(atPath: args[2], contents: nil)
let out = try FileHandle(forWritingTo: URL(fileURLWithPath: args[2]))
var dim = 0

func feature(_ img: CGImage) -> [Float]? {
    let req = VNGenerateImageFeaturePrintRequest()
    req.revision = VNGenerateImageFeaturePrintRequestRevision2
    req.imageCropAndScaleOption = .scaleFill
    do {
        try VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
    } catch {
        return nil
    }
    guard let obs = req.results?.first as? VNFeaturePrintObservation else { return nil }
    let n = obs.elementCount
    var v = [Float](repeating: 0, count: n)
    obs.data.withUnsafeBytes { raw in
        if obs.elementType == .float {
            let p = raw.bindMemory(to: Float.self)
            for i in 0..<n { v[i] = p[i] }
        } else {
            let p = raw.bindMemory(to: Double.self)
            for i in 0..<n { v[i] = Float(p[i]) }
        }
    }
    return v
}

var done = 0
for path in list where !path.isEmpty {
    autoreleasepool {
        var vecs: [[Float]] = []
        if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            for r in REGIONS {
                let rr = r.intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height))
                if let c = img.cropping(to: rr), let v = feature(c) {
                    if dim == 0 {
                        dim = v.count
                        FileHandle.standardError.write("dim \(dim)\n".data(using: .utf8)!)
                    }
                    vecs.append(v)
                } else {
                    vecs.append([])
                }
            }
        }
        if dim == 0 { dim = 768 }
        var buf = [Float]()
        buf.reserveCapacity(dim * REGIONS.count)
        for i in 0..<REGIONS.count {
            let v = i < vecs.count ? vecs[i] : []
            buf += v.count == dim ? v : [Float](repeating: 0, count: dim)
        }
        out.write(buf.withUnsafeBufferPointer { Data(buffer: $0) })
        done += 1
        if done % 500 == 0 {
            FileHandle.standardError.write("\(done)/\(list.count)\n".data(using: .utf8)!)
        }
    }
}
try out.close()
