import Accelerate
import Foundation
import UIKit
import Vision

/// 废片判定信号与打分（全部端侧、零新模型）。
///
/// 信号：
///   1. 模糊 — Laplacian 方差（复用 QualityScorer.laplacianVariance）
///   2. 黑帧/过曝 — 灰度亮度均值极端且方差小（近似纯色）
///   3. 闭眼/表情崩 — VNDetectFaceCaptureQualityRequest 低分且有人脸
///
/// 废片分 junkScore = 0.5·blurBad + 0.3·brightnessBad + 0.2·faceBad，各项 0-1。
/// 分档/过滤阈值由调用方（实验室滑块，默认 0.6）决定；原因标签阈值见 score()。
enum JunkScorer {

    // 归一化常数（定死，保证阈值跨设备稳定、可单测）
    static let blurLow = 5.0      // Laplacian 方差 < 5 → 全模糊
    static let blurHigh = 500.0   // > 500 → 清晰
    static let brightExtremeLo = 0.08   // 平均亮度 < 8%
    static let brightExtremeHi = 0.92   // > 92%
    static let brightUniformStd = 0.06  // 亮度标准差低于此视为近似纯色
    static let reasonBlur = 0.6, reasonBright = 0.5, reasonFace = 0.6

    // MARK: - 纯逻辑（可单测）

    /// 模糊度 0-1：log 域线性，方差越小越模糊。
    static func blurBad(_ rawVariance: Double) -> Double {
        let lo = log10(blurLow + 1), hi = log10(blurHigh + 1)
        return 1 - min(max((log10(rawVariance + 1) - lo) / (hi - lo), 0), 1)
    }

    /// 黑帧/过曝度 0-1：亮度越极端且越均匀（纯色）越像废片。
    static func brightnessBad(mean: Double, std: Double) -> Double {
        let extreme = max(0, max(brightExtremeLo - mean, mean - brightExtremeHi)) / brightExtremeLo
        let uniformity = 1 - min(std / brightUniformStd, 1)
        return min(extreme, 1) * uniformity
    }

    /// 闭眼/表情崩 0-1；无人脸记 0（中性，不影响总分）。
    static func faceBad(hasFace: Bool, faceQuality: Double) -> Double {
        hasFace ? 1 - min(max(faceQuality, 0), 1) : 0
    }

    /// 综合废片分 + 原因标签。
    static func score(_ s: EmbeddingStore.QualityRecord) -> (score: Double, reasons: [String]) {
        let b = blurBad(s.blur)
        let l = brightnessBad(mean: s.brightMean, std: s.brightStd)
        let f = faceBad(hasFace: s.hasFace, faceQuality: s.faceQuality)
        let total = 0.5 * b + 0.3 * l + 0.2 * f
        var reasons: [String] = []
        if b > reasonBlur { reasons.append("模糊") }
        if l > reasonBright { reasons.append(s.brightMean < 0.5 ? "黑帧" : "过曝") }
        if f > reasonFace { reasons.append("闭眼/表情") }
        return (total, reasons)
    }

    /// 废片候选过滤：相机照片（非截图）且分数达到阈值。
    static func isCandidate(score: Double, threshold: Double) -> Bool {
        score >= threshold
    }

    // MARK: - 信号计算（扫描流水线用，~128-256px 小图即可）

    /// 从 UIImage 计算全部信号（模糊 + 亮度 + 人脸）。
    static func computeSignals(_ image: UIImage) -> EmbeddingStore.QualityRecord {
        guard let cg = image.cgImage else {
            return EmbeddingStore.QualityRecord(blur: 0, brightMean: 0, brightStd: 0,
                                                faceQuality: 0.5, hasFace: false)
        }
        let blur = QualityScorer.laplacianVariance(of: cg) ?? 0
        let (mean, std) = brightnessStats(of: cg) ?? (0, 0)
        let faceQ = QualityScorer.maxFaceQuality(of: cg)
        // QualityScorer.maxFaceQuality 无人脸时返回中性 0.5，这里单独探测是否有人脸
        let hasFace = detectAnyFace(in: cg)
        return EmbeddingStore.QualityRecord(
            blur: blur, brightMean: mean, brightStd: std,
            faceQuality: hasFace ? faceQ : 0.5, hasFace: hasFace)
    }

    /// 灰度亮度均值/标准差（128px 降采样）。
    static func brightnessStats(of cgImage: CGImage) -> (mean: Double, std: Double)? {
        let W = cgImage.width, H = cgImage.height
        guard W > 2, H > 2 else { return nil }
        let scale = min(1.0, 128.0 / Double(max(W, H)))
        let w = max(3, Int((Double(W) * scale).rounded()))
        let h = max(3, Int((Double(H) * scale).rounded()))
        var gray = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &gray, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        let n = vDSP_Length(w * h)
        var f = [Float](repeating: 0, count: w * h)
        vDSP_vfltu8(gray, 1, &f, 1, n)
        vDSP_vsdiv(f, 1, [255.0], &f, 1, n)
        var mean: Float = 0, meanSq: Float = 0
        vDSP_meanv(f, 1, &mean, n)
        vDSP_measqv(f, 1, &meanSq, n)
        let variance = max(meanSq - mean * mean, 0)
        return (Double(mean), Double(variance.squareRoot()))
    }

    private static func detectAnyFace(in cgImage: CGImage) -> Bool {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard let _ = try? handler.perform([request]) else { return false }
        return !(request.results?.isEmpty ?? true)
    }
}
