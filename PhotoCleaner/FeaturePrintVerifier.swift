import Foundation
import UIKit
import Vision

/// 第二级"像素级"验证：VNFeaturePrintObservation。
///
/// 语义向量（EmbeddingGemma）分不清"同一张照片的变体"和"同人同景不同姿势"，
/// 特征指纹对像素细节敏感：真重复距离接近 0，不同姿势距离显著更大。
/// 用法：对重复组候选，组内成员与锚点（打分推荐的保留项）算距离，
/// 距离超过阈值的成员被降级到相似组（不进入删除建议）。
enum FeaturePrintVerifier {

    /// 距离阈值：低于此值视为真重复。默认 0.15（可在首页"实验室"滑动调节）。
    /// 校准：精确缩放变体 0.14，连拍位移 0.21，重度压缩 0.33–0.48。
    /// 真机教训：0.20 时 256px 缩略图会把"同场景不同构图"误判为重复（人眼能分辨）。
    static var distanceThreshold: Float {
        let v = UserDefaults.standard.double(forKey: "fpThresholdV2")
        return v > 0 ? Float(v) : 0.15
    }

    /// 返回每个成员到锚点的特征指纹距离（锚点自身为 0）。图片缺失的成员记 .infinity。
    static func distancesToAnchor(anchorID: String, images: [String: UIImage]) -> [String: Float] {
        var prints: [String: VNFeaturePrintObservation] = [:]
        for (id, image) in images {
            guard let cg = image.cgImage else { continue }
            let request = VNGenerateImageFeaturePrintRequest()
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            if let _ = try? handler.perform([request]),
               let obs = request.results?.first {
                prints[id] = obs
            }
        }
        guard let anchorPrint = prints[anchorID] else { return [:] }
        var distances: [String: Float] = [anchorID: 0]
        for (id, obs) in prints where id != anchorID {
            var d: Float = .infinity
            try? anchorPrint.computeDistance(&d, to: obs)
            distances[id] = d
        }
        for id in images.keys where distances[id] == nil {
            distances[id] = .infinity
        }
        return distances
    }
}
