// Классификация вырезок знаков обученной моделью (signtrain).
//
//   signclassify MODEL.mlmodel LIST
//     LIST — файл со списком JPEG. Печатает строку JSON на вырезку:
//     {"f": путь, "l": класс, "p": вероятность, "l2": второй, "p2": его вероятность}
import CoreML
import Foundation
import Vision

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: signclassify MODEL.mlmodel LIST\n".data(using: .utf8)!)
    exit(2)
}
let src = URL(fileURLWithPath: args[1])
let compiled: URL
do {
    compiled = src.pathExtension == "mlmodelc" ? src : try MLModel.compileModel(at: src)
} catch {
    FileHandle.standardError.write("модель не собирается: \(error)\n".data(using: .utf8)!)
    exit(1)
}
let cfg = MLModelConfiguration()
cfg.computeUnits = .cpuAndNeuralEngine
guard let ml = try? MLModel(contentsOf: compiled, configuration: cfg), let vm = try? VNCoreMLModel(for: ml) else {
    FileHandle.standardError.write("модель не загружается\n".data(using: .utf8)!)
    exit(1)
}
let paths = try String(contentsOfFile: args[2], encoding: .utf8).split(separator: "\n").map(String.init)
    .filter { !$0.isEmpty }
for p in paths {
    autoreleasepool {
        let req = VNCoreMLRequest(model: vm)
        req.imageCropAndScaleOption = .scaleFill
        do {
            try VNImageRequestHandler(url: URL(fileURLWithPath: p)).perform([req])
            let obs = (req.results as? [VNClassificationObservation] ?? []).sorted { $0.confidence > $1.confidence }
            guard let a = obs.first else { return }
            var out: [String: Any] = ["f": p, "l": a.identifier, "p": Double(a.confidence)]
            if obs.count > 1 { out["l2"] = obs[1].identifier; out["p2"] = Double(obs[1].confidence) }
            print(String(data: try JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
        } catch {
            FileHandle.standardError.write("\(p): \(error)\n".data(using: .utf8)!)
        }
    }
}
