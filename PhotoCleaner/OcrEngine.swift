import Foundation
import UIKit
import Vision

/// 端侧 OCR：VNRecognizeTextRequest fast 档，中英文，识别结果按行空格连接。
/// 对 512px 图在 A15 上约 50-100ms。
enum OcrEngine {

    /// 返回识别文本（空格连接）；无文字返回空串（调用方仍应写库，作为"已跑过"标记）。
    static func recognizeText(_ image: UIImage) -> String {
        guard let cg = image.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        guard let _ = try? handler.perform([request]),
              let observations = request.results else { return "" }
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
    }
}
