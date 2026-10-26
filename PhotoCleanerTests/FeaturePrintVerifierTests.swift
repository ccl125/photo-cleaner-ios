import XCTest
@testable import PhotoCleaner

/// FeaturePrintVerifier.distanceThreshold 的阈值读取逻辑（纯 UserDefaults，不碰 Vision）。
final class FeaturePrintVerifierTests: XCTestCase {

    private let key = "fpThresholdV2"
    private var savedValue: Double?

    override func setUp() {
        super.setUp()
        // 保存现场，用例结束后还原，避免污染宿主 App 的用户设置
        if UserDefaults.standard.object(forKey: key) != nil {
            savedValue = UserDefaults.standard.double(forKey: key)
        }
    }

    override func tearDown() {
        if let savedValue {
            UserDefaults.standard.set(savedValue, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    /// 未设置过（用户没动过滑块）时回退到默认 0.15。
    func testDefaultThresholdWhenUnset() {
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(FeaturePrintVerifier.distanceThreshold, 0.15, accuracy: 1e-6)
    }

    /// 用户设定值原样生效。
    func testUserDefinedThresholdIsHonored() {
        UserDefaults.standard.set(0.30, forKey: key)
        XCTAssertEqual(FeaturePrintVerifier.distanceThreshold, 0.30, accuracy: 1e-6)
    }

    /// 0 与负数是非法值，回退默认 0.15（double(forKey:) 对缺失键也返回 0，
    /// 两种情形走同一条回退路径）。
    func testNonPositiveValuesFallBackToDefault() {
        UserDefaults.standard.set(0.0, forKey: key)
        XCTAssertEqual(FeaturePrintVerifier.distanceThreshold, 0.15, accuracy: 1e-6)
        UserDefaults.standard.set(-0.2, forKey: key)
        XCTAssertEqual(FeaturePrintVerifier.distanceThreshold, 0.15, accuracy: 1e-6)
    }
}
