// Классификатор «камера фиксации близко / нет» — Create ML на маке.
//
//   camnet train DATA_DIR MODEL_OUT [ITER]  — DATA_DIR/{train,val}/{camera,none};
//                                             печатает точность на val (JSON)
//   camnet predict MODEL LIST [TOPFRAC]     — LIST: файл со списком JPEG;
//                                             stdout «путь\tвероятность camera».
//                                             TOPFRAC — доля высоты сверху (ROI):
//                                             целые кадры 1280×529 → 380/529
//
// Выборка собирается без человека (dataset.py): моменты проездов камер из GPX
// с исправленным временем (wpt опаздывает на ~720 м пути, см. passes.py).
import CoreML
import CreateML
import Foundation
import Vision

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: camnet train DATA MODEL [ITER] | predict MODEL LIST\n".data(using: .utf8)!)
    exit(2)
}

if args[1] == "train" {
    let data = URL(fileURLWithPath: args[2])
    let train = MLImageClassifier.DataSource.labeledDirectories(at: data.appendingPathComponent("train"))
    let val = MLImageClassifier.DataSource.labeledDirectories(at: data.appendingPathComponent("val"))
    let iters = args.count > 4 ? Int(args[4]) ?? 60 : 60
    let params = MLImageClassifier.ModelParameters(
        validation: .dataSource(val), maxIterations: iters, augmentation: [.flip],
        algorithm: .transferLearning(featureExtractor: .scenePrint(revision: 2), classifier: .logisticRegressor))
    let model = try MLImageClassifier(trainingData: train, parameters: params)
    let ev = model.evaluation(on: val)
    try model.write(to: URL(fileURLWithPath: args[3]))
    var rows: [String] = []
    for r in ev.confusion.rows {
        let t = r["True Label"]?.stringValue ?? "?"
        let p = r["Predicted"]?.stringValue ?? "?"
        let n = r["Count"]?.intValue ?? 0
        rows.append("{\"true\":\"\(t)\",\"pred\":\"\(p)\",\"n\":\(n)}")
    }
    print("{\"train_acc\":\(1 - model.trainingMetrics.classificationError),"
          + "\"val_acc\":\(1 - ev.classificationError),\"confusion\":[\(rows.joined(separator: ","))]}")
} else if args[1] == "predict" {
    let compiled = try MLModel.compileModel(at: URL(fileURLWithPath: args[2]))
    let ml = try MLModel(contentsOf: compiled)
    let vm = try VNCoreMLModel(for: ml)
    let list = try String(contentsOfFile: args[3], encoding: .utf8).split(separator: "\n").map(String.init)
    let top = args.count > 4 ? Double(args[4]) ?? 1.0 : 1.0
    for path in list where !path.isEmpty {
        autoreleasepool {
            let req = VNCoreMLRequest(model: vm)
            req.imageCropAndScaleOption = .scaleFill
            // Vision: начало координат ROI — внизу слева, доли кадра
            req.regionOfInterest = CGRect(x: 0, y: 1 - top, width: 1, height: top)
            do {
                try VNImageRequestHandler(url: URL(fileURLWithPath: path)).perform([req])
                let res = (req.results as? [VNClassificationObservation]) ?? []
                let p = res.first(where: { $0.identifier == "camera" })?.confidence ?? 0
                print("\(path)\t\(p)")
            } catch {
                print("\(path)\t-1")
            }
        }
    }
    fflush(stdout)
}
