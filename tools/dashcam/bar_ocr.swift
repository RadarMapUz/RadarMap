// OCR верхней полосы кадра регистратора BYD: «46km/h … 2026-10-07 08:15:23».
// Вход — папка png-вырезок полосы; выход в stdout — CSV «файл,время,скорость»
// (пустое поле — не прочиталось). Собирает overlay.py через swiftc.
import AppKit
import Foundation
import Vision

let dir = CommandLine.arguments[1]
let files = try FileManager.default.contentsOfDirectory(atPath: dir)
    .filter { $0.hasSuffix(".png") }.sorted()
let speedRe = try NSRegularExpression(pattern: #"(\d{1,3})\s*km/h"#)
let timeRe = try NSRegularExpression(pattern: #"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})"#)

func first(_ re: NSRegularExpression, _ s: String) -> String? {
    guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
          let r = Range(m.range(at: 1), in: s) else { return nil }
    return String(s[r])
}

print("file,time,speed")
for name in files {
    guard let img = NSImage(contentsOfFile: dir + "/" + name),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        print("\(name),,")
        continue
    }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = false
    do {
        try VNImageRequestHandler(cgImage: cg).perform([req])
    } catch {
        FileHandle.standardError.write("ошибка Vision на \(name): \(error)\n".data(using: .utf8)!)
    }
    let text = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: " ")
    print("\(name),\(first(timeRe, text) ?? ""),\(first(speedRe, text) ?? "")")
}
