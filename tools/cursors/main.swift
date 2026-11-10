import Foundation

// Запуск: swiftc -O tools/cursors/*.swift -o /tmp/cursors && /tmp/cursors RadarMap/Assets.xcassets/Cursors [--preview DIR] [id…]
let args = Array(CommandLine.arguments.dropFirst())
guard let out = args.first else {
    print("использование: cursors <каталог imageset> [--preview DIR] [id…]")
    exit(1)
}
var rest = Array(args.dropFirst())
var previewDir: String?
if let i = rest.firstIndex(of: "--preview"), i + 1 < rest.count {
    previewDir = rest[i + 1]
    rest.removeSubrange(i...(i + 1))
}
let only = Set(rest)
let fm = FileManager.default
try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
let folder = "\(out)/Contents.json"
if !fm.fileExists(atPath: folder) {
    try! "{\n  \"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }\n}\n".write(toFile: folder, atomically: true, encoding: .utf8)
}

let superPx = 20.0
for v in vehicles where only.isEmpty || only.contains(v.id) {
    let done = finish(renderRaw(v, pxPerPt: superPx), pxPerPt: superPx)
    let name = "cursor-\(v.id)"
    let set = "\(out)/\(name).imageset"
    try? fm.createDirectory(atPath: set, withIntermediateDirectories: true)
    for scale in [2, 3] {
        let img = downscale(done, to: CGSize(width: canvasPt.width * CGFloat(scale), height: canvasPt.height * CGFloat(scale)))
        writePNG(img, "\(set)/\(name)@\(scale)x.png")
    }
    let contents = """
    {
      "images" : [
        {
          "idiom" : "universal",
          "scale" : "1x"
        },
        {
          "filename" : "\(name)@2x.png",
          "idiom" : "universal",
          "scale" : "2x"
        },
        {
          "filename" : "\(name)@3x.png",
          "idiom" : "universal",
          "scale" : "3x"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
    try! contents.write(toFile: "\(set)/Contents.json", atomically: true, encoding: .utf8)
    if let dir = previewDir {
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        writePNG(downscale(done, to: CGSize(width: canvasPt.width * 10, height: canvasPt.height * 10)), "\(dir)/\(name)_preview.png")
    }
    print(name)
}
