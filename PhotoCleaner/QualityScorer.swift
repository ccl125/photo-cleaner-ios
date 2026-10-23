import Accelerate
import Foundation
import Photos
import UIKit
import Vision

/// 组内质量打分（全部端侧、零新模型）：
///   模糊 40%（Laplacian 方差，PlanarF 卷积不截断，log 后组内 min-max 归一）
/// + 人脸 30%（VNDetectFaceCaptureQualityRequest 最高值，无人脸记中性 0.5）
/// + 分辨率 30%（pixelWidth*pixelHeight 按组内最大值归一）
/// 只对相似组内的成员（通常 2-10 张）调用，不做全库打分。
enum QualityScorer {

    struct MemberScore {
        var blur: Double
        var face: Double
        var resolution: Double
        var composite: Double
    }

    /// 返回每个 asset localIdentifier 的分数与推荐保留的 id（综合分最高者）。
    /// - Parameters:
    ///   - assets: 组内成员
    ///   - images: localIdentifier -> 约 512px 的 UIImage（拉取失败的成员不含在内）
    static func scoreGroup(assets: [PHAsset],
                           images: [String: UIImage]) -> (scores: [String: MemberScore], recommended: String?) {
        let n = assets.count
        guard n > 0 else { return ([:], nil) }

        // 原始分
        var blurRaw = [Double]()   // log10(laplacian variance + 1)
        var faceRaw = [Double]()
        var resRaw = [Double]()    // 像素数
        for asset in assets {
            if let img = images[asset.localIdentifier], let cg = img.cgImage {
                blurRaw.append(log10((laplacianVariance(of: cg) ?? 0) + 1))
                faceRaw.append(maxFaceQuality(of: cg))
            } else {
                blurRaw.append(0)
                faceRaw.append(0.5)
            }
            resRaw.append(Double(asset.pixelWidth * asset.pixelHeight))
        }

        // 组内无量纲化
        let blurNorm = minMaxNormalize(blurRaw)
        let resMax = resRaw.max() ?? 1
        let resNorm = resRaw.map { $0 / max(resMax, 1) }

        var scores: [String: MemberScore] = [:]
        var bestID: String?
        var bestComposite = -Double.infinity
        for (i, asset) in assets.enumerated() {
            let face = faceRaw[i] // 本身已是 [0,1]
            let composite = 0.4 * blurNorm[i] + 0.3 * face + 0.3 * resNorm[i]
            scores[asset.localIdentifier] = MemberScore(
                blur: blurNorm[i], face: face, resolution: resNorm[i], composite: composite)
            if composite > bestComposite {
                bestComposite = composite
                bestID = asset.localIdentifier
            }
        }
        return (scores, bestID)
    }

    // MARK: - 模糊：Laplacian 方差（降采样灰度 + PlanarF 卷积）

    static func laplacianVariance(of cgImage: CGImage) -> Double? {
        let W = cgImage.width, H = cgImage.height
        guard W > 2, H > 2 else { return nil }
        let scale = min(1.0, 256.0 / Double(max(W, H)))
        let w = max(3, Int((Double(W) * scale).rounded()))
        let h = max(3, Int((Double(H) * scale).rounded()))

        var gray = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &gray, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        let count = w * h
        var src = [Float](repeating: 0, count: count)
        vDSP_vfltu8(gray, 1, &src, 1, vDSP_Length(count))
        var dst = [Float](repeating: 0, count: count)
        var kernel: [Float] = [0, 1, 0,
                               1, -4, 1,
                               0, 1, 0]
        src.withUnsafeMutableBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                var vsrc = vImage_Buffer(data: s.baseAddress!, height: vImagePixelCount(h),
                                         width: vImagePixelCount(w), rowBytes: w * MemoryLayout<Float>.size)
                var vdst = vImage_Buffer(data: d.baseAddress!, height: vImagePixelCount(h),
                                         width: vImagePixelCount(w), rowBytes: w * MemoryLayout<Float>.size)
                kernel.withUnsafeBufferPointer { k in
                    _ = vImageConvolve_PlanarF(&vsrc, &vdst, nil, 0, 0, k.baseAddress!, 3, 3,
                                               0, vImage_Flags(kvImageEdgeExtend))
                }
            }
        }
        var mean: Float = 0, meanSq: Float = 0
        vDSP_meanv(dst, 1, &mean, vDSP_Length(count))
        vDSP_measqv(dst, 1, &meanSq, vDSP_Length(count))
        return Double(max(meanSq - mean * mean, 0))
    }

    // MARK: - 人脸质量

    /// 最高 faceCaptureQuality；无人脸或检测失败返回中性 0.5。
    static func maxFaceQuality(of cgImage: CGImage) -> Double {
        let request = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard let _ = try? handler.perform([request]),
              let faces = request.results, !faces.isEmpty else { return 0.5 }
        let best = faces.compactMap(\.faceCaptureQuality).max()
        return Double(best ?? 0.5)
    }

    // MARK: - 工具

    /// min-max 归一到 [0,1]；全部相等时都给 1（该维度无区分度，不惩罚任何一张）。
    private static func minMaxNormalize(_ xs: [Double]) -> [Double] {
        guard let lo = xs.min(), let hi = xs.max(), hi > lo else {
            return xs.map { _ in 1.0 }
        }
        return xs.map { ($0 - lo) / (hi - lo) }
    }
}
