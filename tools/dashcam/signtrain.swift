// Обучение классификатора вырезок знаков (Create ML, перенос признаков
// Vision scenePrint + логистическая регрессия).
//
//   signtrain TRAIN_DIR VAL_DIR OUT.mlmodel [ITER]
//     TRAIN_DIR/VAL_DIR — <класс>/<id>.jpg (деление по поездкам делает signs.py)
//     Печатает JSON с точностью на обучении и проверке.
//
// Аугментация — без отражения и поворота: «объезд справа» и «объезд слева»,
// разворот и «только прямо» различаются именно направлением стрелки.
import CreateML
import Foundation

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: signtrain TRAIN_DIR VAL_DIR OUT.mlmodel [ITER]\n".data(using: .utf8)!)
    exit(2)
}
let trainURL = URL(fileURLWithPath: args[1])
let valURL = URL(fileURLWithPath: args[2])
let outURL = URL(fileURLWithPath: args[3])
let iters = args.count > 4 ? Int(args[4]) ?? 40 : 40

do {
    let params = MLImageClassifier.ModelParameters(
        validation: .dataSource(.labeledDirectories(at: valURL)),
        maxIterations: iters,
        augmentation: [.crop, .blur, .exposure, .noise],
        algorithm: .transferLearning(featureExtractor: .scenePrint(revision: 2), classifier: .logisticRegressor))
    let model = try MLImageClassifier(trainingData: .labeledDirectories(at: trainURL), parameters: params)
    let meta = MLModelMetadata(author: "RadarMap dashcam", shortDescription: "Классы вырезок дорожных знаков",
                               version: "1")
    try model.write(to: outURL, metadata: meta)
    let out: [String: Any] = [
        "train_error": model.trainingMetrics.classificationError,
        "val_error": model.validationMetrics.classificationError,
        "model": outURL.path,
    ]
    print(String(data: try JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
} catch {
    FileHandle.standardError.write("ошибка обучения: \(error)\n".data(using: .utf8)!)
    exit(1)
}
