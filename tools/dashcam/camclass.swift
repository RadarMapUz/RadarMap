// Классификатор кадра «камера фиксации близко / нет» — Create ML на маке.
//
//   camclass train DATA_DIR MODEL_OUT      — DATA_DIR/train/{camera,none}, DATA_DIR/val/{…};
//                                            печатает точность на val (JSON)
//   camclass predict MODEL LIST            — LIST: файл со списком JPEG;
//                                            в stdout «путь\tвероятность camera»
//
// Обучающая выборка без человека: «camera» — кадры за 0,3–3 с до проезда
// камеры из GPX (камера в кадре впереди), «none» — кадры > 300 м от любой
// камеры базы. Деление train/val — по поездкам (см. selfcam.py).
import CoreML
import CreateML
import Foundation
import Vision

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: camclass train DATA MODEL | predict MODEL LIST\n".data(using: .utf8)!)
    exit(2)
}

if args[1] == "train" {
    let data = URL(fileURLWithPath: args[2])
    let train = MLImageClassifier.DataSource.labeledDirectories(at: data.appendingPathComponent("train"))
    let val = MLImageClassifier.DataSource.labeledDirectories(at: data.appendingPathComponent("val"))
    var params = MLImageClassifier.ModelParameters()
    params.maxIterations = 40
    params.augmentationOptions = [.flip]
    params.validation = .dataSource(val)
    let model = try MLImageClassifier(trainingData: train, parameters: params)
    let ev = model.evaluation(on: val)
    try model.write(to: URL(fileURLWithPath: args[3]))
    // Матрица ошибок по классам
    var rows: [String] = []
    let cm = ev.confusion
    for r in cm.rows {
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
    for path in list where !path.isEmpty {
        autoreleasepool {
            let req = VNCoreMLRequest(model: vm)
            req.imageCropAndScaleOption = .scaleFill
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
