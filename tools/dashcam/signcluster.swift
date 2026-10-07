// Кластеры вырезок знаков для быстрой подписи: эмбеддинг Vision
// (VNGenerateImageFeaturePrintRequest) + k-means (k-means++ с фиксированным
// зерном — повторный запуск даёт те же кластеры).
//
//   signcluster LIST K OUT.json
//     LIST — файл со списком JPEG; OUT — {"clusters":[{"members":[путь…],"reps":[9 путей]}]}
//     reps — 9 вырезок ближе всего к центру кластера (их и видит человек).
import Foundation
import Vision

let args = CommandLine.arguments
guard args.count >= 4, let K0 = Int(args[2]) else {
    FileHandle.standardError.write("usage: signcluster LIST K OUT.json\n".data(using: .utf8)!)
    exit(2)
}
let paths = try String(contentsOfFile: args[1], encoding: .utf8).split(separator: "\n").map(String.init)
    .filter { !$0.isEmpty }

var vecs: [[Float]] = []
var kept: [String] = []
for p in paths {
    autoreleasepool {
        let req = VNGenerateImageFeaturePrintRequest()
        req.imageCropAndScaleOption = .scaleFill
        do {
            try VNImageRequestHandler(url: URL(fileURLWithPath: p)).perform([req])
            guard let fp = req.results?.first as? VNFeaturePrintObservation, fp.elementType == .float else { return }
            var v = [Float](repeating: 0, count: fp.elementCount)
            fp.data.withUnsafeBytes { raw in
                let b = raw.bindMemory(to: Float.self)
                for i in 0..<fp.elementCount { v[i] = b[i] }
            }
            // нормировка: косинусная близость через евклидову
            var n: Float = 0
            for x in v { n += x * x }
            n = max(sqrt(n), 1e-6)
            vecs.append(v.map { $0 / n })
            kept.append(p)
        } catch {}
    }
}

func dist2(_ a: [Float], _ b: [Float]) -> Float {
    var s: Float = 0
    for i in 0..<a.count { let d = a[i] - b[i]; s += d * d }
    return s
}

let N = vecs.count
let K = max(1, min(K0, N))
var rng = SystemRandomNumberGenerator()
struct LCG { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) } }
var lcg = LCG(s: 42)
var cents: [[Float]] = []
if N > 0 {
    cents.append(vecs[Int(lcg.next() * Double(N)) % N])
    var dmin = vecs.map { dist2($0, cents[0]) }
    while cents.count < K {
        let tot = dmin.reduce(0, +)
        var r = Float(lcg.next()) * tot
        var pick = 0
        for i in 0..<N { r -= dmin[i]; if r <= 0 { pick = i; break } }
        cents.append(vecs[pick])
        for i in 0..<N { dmin[i] = min(dmin[i], dist2(vecs[i], vecs[pick])) }
    }
}
var assign = [Int](repeating: 0, count: N)
for _ in 0..<25 {
    var changed = false
    for i in 0..<N {
        var best = 0, bd = Float.infinity
        for k in 0..<cents.count { let d = dist2(vecs[i], cents[k]); if d < bd { bd = d; best = k } }
        if assign[i] != best { assign[i] = best; changed = true }
    }
    var sums = [[Float]](repeating: [Float](repeating: 0, count: vecs.first?.count ?? 0), count: cents.count)
    var cnt = [Int](repeating: 0, count: cents.count)
    for i in 0..<N { cnt[assign[i]] += 1; for j in 0..<vecs[i].count { sums[assign[i]][j] += vecs[i][j] } }
    for k in 0..<cents.count where cnt[k] > 0 { cents[k] = sums[k].map { $0 / Float(cnt[k]) } }
    if !changed { break }
}
var out: [[String: [String]]] = []
for k in 0..<cents.count {
    let idx = (0..<N).filter { assign[$0] == k }
    if idx.isEmpty { continue }
    let reps = idx.sorted { dist2(vecs[$0], cents[k]) < dist2(vecs[$1], cents[k]) }.prefix(9).map { kept[$0] }
    out.append(["members": idx.map { kept[$0] }, "reps": Array(reps)])
}
let json = try JSONSerialization.data(withJSONObject: ["clusters": out], options: [])
try json.write(to: URL(fileURLWithPath: args[3]))
print("ok \(N) \(out.count)")
