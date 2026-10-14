// 本地离线 OCR：基于 macOS Vision 框架（VNRecognizeTextRequest）。
//
// 无需安装任何第三方依赖，调用协议与 README §4.3 的 PaddleOCR 约定一致：
//   ocr_vision --image "<图片绝对路径>" [--lang ch]
// stdout 输出 JSON：
//   {"code":0,"message":"ok","full_text":"...","lines":["..."]}
//
// 出错时写 stderr 并以非 0 退出码结束。

import Foundation
import Vision
import AppKit

func emitError(_ code: Int32, _ message: String) -> Never {
    FileHandle.standardError.write(Data(("ocr_vision: " + message + "\n").utf8))
    exit(code)
}

func emitJSON(_ object: [String: Any]) {
    guard
        let data = try? JSONSerialization.data(withJSONObject: object),
        let text = String(data: data, encoding: .utf8)
    else {
        emitError(5, "failed to encode JSON output")
    }
    print(text)
}

// ---------- 解析参数 ----------
let arguments = CommandLine.arguments
var imagePath: String?
var lang = "ch"
var index = 1
while index < arguments.count {
    switch arguments[index] {
    case "--image":
        index += 1
        if index < arguments.count { imagePath = arguments[index] }
    case "--lang":
        index += 1
        if index < arguments.count { lang = arguments[index] }
    default:
        break
    }
    index += 1
}

guard let path = imagePath else {
    emitError(2, "missing --image argument")
}
guard FileManager.default.fileExists(atPath: path) else {
    emitError(2, "image file not found: \(path)")
}
guard let image = NSImage(contentsOfFile: path),
    let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    emitError(3, "cannot load image: \(path)")
}

// ---------- 识别 ----------
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true
if #available(macOS 11.0, *) {
    request.recognitionLanguages = (lang == "ch") ? ["zh-Hans", "en-US"] : ["en-US"]
}

let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
do {
    try handler.perform([request])
} catch {
    emitError(4, "OCR failed: \(error.localizedDescription)")
}

var lines: [String] = []
if let observations = request.results {
    for observation in observations {
        if let candidate = observation.topCandidates(1).first {
            lines.append(candidate.string)
        }
    }
}

emitJSON([
    "code": 0,
    "message": "ok",
    "full_text": lines.joined(separator: "\n"),
    "lines": lines,
])
