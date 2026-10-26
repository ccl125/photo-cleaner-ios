import XCTest
@testable import PhotoCleaner

/// 废片分（JunkScorer）纯逻辑测试：构造质量信号，断言归一化、排序与阈值过滤。
/// 不碰 PhotoKit / Core ML / Vision。
final class JunkScorerTests: XCTestCase {

    private func record(blur: Double = 500, mean: Double = 0.5, std: Double = 0.2,
                        faceQuality: Double = 0.5, hasFace: Bool = false) -> EmbeddingStore.QualityRecord {
        EmbeddingStore.QualityRecord(blur: blur, brightMean: mean, brightStd: std,
                                     faceQuality: faceQuality, hasFace: hasFace)
    }

    // MARK: - 模糊归一化

    func testBlurBadOrdering() {
        let sharp = JunkScorer.blurBad(2000)   // 清晰
        let normal = JunkScorer.blurBad(100)
        let blurry = JunkScorer.blurBad(2)     // 手抖
        XCTAssertLessThan(sharp, 0.05)
        XCTAssertGreaterThan(blurry, 0.95)
        XCTAssertLessThan(sharp, normal)
        XCTAssertLessThan(normal, blurry)
    }

    // MARK: - 黑帧/过曝

    func testBrightnessBad() {
        // 纯黑帧（完全无信息）：极暗且完全均匀 → 1
        XCTAssertEqual(JunkScorer.brightnessBad(mean: 0.0, std: 0.0), 1.0, accuracy: 1e-6)
        // 纯白帧
        XCTAssertEqual(JunkScorer.brightnessBad(mean: 1.0, std: 0.0), 1.0, accuracy: 1e-6)
        // 正常照片：不极端 → 0
        XCTAssertEqual(JunkScorer.brightnessBad(mean: 0.5, std: 0.2), 0.0, accuracy: 1e-6)
        // 暗但有内容（夜景）：极暗但不完全均匀 → 部分分
        let night = JunkScorer.brightnessBad(mean: 0.04, std: 0.045)
        XCTAssertGreaterThan(night, 0)
        XCTAssertLessThan(night, 0.5)
    }

    // MARK: - 人脸

    func testFaceBadNeutralWithoutFace() {
        // 无人脸 → 中性 0，不贡献废片分
        XCTAssertEqual(JunkScorer.faceBad(hasFace: false, faceQuality: 0.1), 0)
        // 有人脸且质量低 → 接近 1
        XCTAssertEqual(JunkScorer.faceBad(hasFace: true, faceQuality: 0.1), 0.9, accuracy: 1e-6)
        // 有人脸且质量高 → 接近 0
        XCTAssertLessThan(JunkScorer.faceBad(hasFace: true, faceQuality: 0.95), 0.1)
    }

    // MARK: - 综合分与阈值过滤

    func testScoreOrderingAndThreshold() {
        let junk = record(blur: 1, mean: 0.02, std: 0.01, faceQuality: 0.1, hasFace: true)
        let blurryOnly = record(blur: 1)
        let good = record()

        let junkScore = JunkScorer.score(junk).score
        let blurryScore = JunkScorer.score(blurryOnly).score
        let goodScore = JunkScorer.score(good).score

        // 排序：全中废片 > 仅模糊 > 好照片
        XCTAssertGreaterThan(junkScore, blurryScore)
        XCTAssertGreaterThan(blurryScore, goodScore)

        // 默认阈值 0.6：全中废片入选，好照片不进
        XCTAssertTrue(JunkScorer.isCandidate(score: junkScore, threshold: 0.6))
        XCTAssertFalse(JunkScorer.isCandidate(score: goodScore, threshold: 0.6))

        // 原因标签
        let reasons = JunkScorer.score(junk).reasons
        XCTAssertTrue(reasons.contains("模糊"))
        XCTAssertTrue(reasons.contains("黑帧"))
        XCTAssertTrue(reasons.contains("闭眼/表情"))
        XCTAssertTrue(JunkScorer.score(good).reasons.isEmpty)
    }
}
