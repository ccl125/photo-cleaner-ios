import XCTest
@testable import PhotoCleaner

/// 星型聚类（DedupAnalyzer.findGroups）的纯逻辑测试：
/// 全部用构造的 256 维 L2 归一化假向量，不碰 PhotoKit / Core ML。
/// 存储走 EmbeddingStore（SQLite），每个用例开全新临时库。
final class DedupAnalyzerTests: XCTestCase {

    // MARK: - 工具

    /// 全新空库（删掉宿主 App Documents 下的 embeddings.sqlite 再开）。
    private func makeStore() throws -> EmbeddingStore {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("embeddings.sqlite")
        try? FileManager.default.removeItem(at: url)
        let store = EmbeddingStore()
        try store.open()
        return store
    }

    override func tearDown() {
        super.tearDown()
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: docs.appendingPathComponent("embeddings.sqlite"))
    }

    private let dim = 256

    /// 第 axis 个分量为 value、其余为 0 的向量（未归一化，由调用方保证整体单位模长）。
    private func basis(_ axis: Int, _ value: Float = 1) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        v[axis] = value
        return v
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in 0..<dim { s += a[i] * b[i] }
        return s
    }

    private func insert(_ store: EmbeddingStore, _ vectors: [(String, [Float])]) {
        for (id, v) in vectors { store.insert(id: id, vector: v) }
    }

    // MARK: - ① 链式场景：A~B~C~D~E 相邻相似，首尾不得同组（3357 张假组的回归测试）

    /// union-find 会把相邻相似的链式照片传递合并成一个巨组（真机教训：
    /// 4,594 张里最大组 3,357 张）。星型聚类要求每个成员直接与锚点相似，
    /// 链两端必须被切开。
    ///
    /// 构造：v_i = cos((i-1)α)·e0 + sin((i-1)α)·e1，cos α = 0.98。
    /// 相邻对 cosine = 0.98（> 0.97 重复档）；相隔 2 位 = 0.921（相似档）；
    /// 相隔 3 位 = 0.825、相隔 4 位 = 0.696（不成对）。
    /// 注意：相似度在几何上必然衰减（相邻 c 则次邻 ≥ 2c²−1），这正是
    /// union-find 链式合并的成因，也是本用例要锁死的行为。
    func testChainDoesNotFormSingleGroup() throws {
        let store = try makeStore()
        let alpha = acos(0.98 as Float)
        var vectors: [(String, [Float])] = []
        for i in 0..<5 {
            let ang = Float(i) * alpha
            var v = [Float](repeating: 0, count: dim)
            v[0] = cos(ang)
            v[1] = sin(ang)
            vectors.append(("chain\(i)", v))
        }
        insert(store, vectors)

        let groups = DedupAnalyzer.findGroups(store: store)

        // 不得出现包含全部 5 张的巨组（union-find 的失败模式）
        XCTAssertFalse(groups.contains { $0.assetIDs.count == 5 },
                       "链式场景不得合并成单个 5 张巨组: \(groups.map { $0.assetIDs })")
        // 链两端 chain0 / chain4 不得同组
        for g in groups {
            XCTAssertFalse(g.assetIDs.contains("chain0") && g.assetIDs.contains("chain4"),
                           "链两端不得同组: \(g.assetIDs)")
        }
        // 星型聚类不变式：每个成员与锚点（assetIDs[0]）的 cosine 必须过该组档位阈值
        let vecByID = Dictionary(uniqueKeysWithValues: vectors)
        for g in groups {
            let anchor = vecByID[g.assetIDs[0]]!
            let lo: Float = g.tier == .duplicate
                ? DedupAnalyzer.duplicateThreshold : DedupAnalyzer.similarThreshold
            for id in g.assetIDs.dropFirst() {
                XCTAssertGreaterThan(cosine(anchor, vecByID[id]!), lo,
                                     "\(id) 与锚点不直接相似，违反星型聚类不变式")
            }
        }
    }

    // MARK: - ② 真重复簇：全部两两相似，应成同一个重复组

    /// 构造 4 张两两 cosine = 0.985 的向量：v_i = a·e0 + b·e(i+1)，a²=0.985。
    func testTrueDuplicateClusterFormsOneGroup() throws {
        let store = try makeStore()
        let a = sqrtf(0.985)
        let b = sqrtf(0.015)
        var vectors: [(String, [Float])] = []
        for i in 0..<4 {
            var v = [Float](repeating: 0, count: dim)
            v[0] = a
            v[i + 1] = b
            vectors.append(("dup\(i)", v))
        }
        // 自检：确实两两 > 0.97
        for i in 0..<4 {
            for j in (i + 1)..<4 {
                XCTAssertGreaterThan(cosine(vectors[i].1, vectors[j].1),
                                     DedupAnalyzer.duplicateThreshold)
            }
        }
        insert(store, vectors)

        let groups = DedupAnalyzer.findGroups(store: store)
        XCTAssertEqual(groups.count, 1, "真重复簇应恰好成 1 组: \(groups.map { $0.assetIDs })")
        XCTAssertEqual(groups.first?.tier, .duplicate)
        XCTAssertEqual(Set(groups.first?.assetIDs ?? []),
                       ["dup0", "dup1", "dup2", "dup3"])
    }

    // MARK: - ③ 双阈值分档互斥

    /// 一对重复（cosine 0.99）+ 一对相似（cosine 0.94），两对互不相关：
    /// 重复对进 duplicate 组，相似对进 similar 组，互不串档。
    func testTierSeparationIsMutuallyExclusive() throws {
        let store = try makeStore()
        let v1 = basis(0)
        var v2 = [Float](repeating: 0, count: dim)
        v2[0] = 0.99
        v2[1] = sqrtf(1 - 0.99 * 0.99)
        let w1 = basis(2)
        var w2 = [Float](repeating: 0, count: dim)
        w2[2] = 0.94
        w2[3] = sqrtf(1 - 0.94 * 0.94)
        insert(store, [("v1", v1), ("v2", v2), ("w1", w1), ("w2", w2)])

        let groups = DedupAnalyzer.findGroups(store: store)
        XCTAssertEqual(groups.count, 2, "应各成一组: \(groups.map { ($0.tier, $0.assetIDs) })")

        let dupGroup = groups.first { $0.assetIDs.contains("v1") }
        let simGroup = groups.first { $0.assetIDs.contains("w1") }
        XCTAssertEqual(dupGroup?.tier, .duplicate, "0.99 的对子应进重复组")
        XCTAssertEqual(simGroup?.tier, .similar, "0.94 的对子应进相似组")
        XCTAssertEqual(Set(dupGroup?.assetIDs ?? []), ["v1", "v2"])
        XCTAssertEqual(Set(simGroup?.assetIDs ?? []), ["w1", "w2"])
    }

    // MARK: - ④ 单张不成组 / 互不相似不成组

    func testSingleAssetFormsNoGroup() throws {
        let store = try makeStore()
        insert(store, [("lonely", basis(0))])
        XCTAssertTrue(DedupAnalyzer.findGroups(store: store).isEmpty)
    }

    func testDissimilarAssetsFormNoGroup() throws {
        let store = try makeStore()
        // 三个正交向量，cosine 全为 0
        insert(store, [("x", basis(0)), ("y", basis(1)), ("z", basis(2))])
        XCTAssertTrue(DedupAnalyzer.findGroups(store: store).isEmpty)
    }
}
