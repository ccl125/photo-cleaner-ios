import XCTest
@testable import PhotoCleaner

/// EmbeddingStore（SQLite3 C API）的往返一致性测试。
/// 用真实 SQLite 库（宿主 App Documents 下的 embeddings.sqlite，用例前删库重开），
/// 不碰模型与 PhotoKit。
final class EmbeddingStoreTests: XCTestCase {

    private var store: EmbeddingStore!
    private let dim = 256

    private var dbURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("embeddings.sqlite")
    }

    override func setUpWithError() throws {
        try? FileManager.default.removeItem(at: dbURL)
        store = EmbeddingStore()
        try store.open()
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(at: dbURL)
        super.tearDown()
    }

    /// 生成确定性的 256 维假向量（内容可区分即可，无需归一化）。
    private func vector(seed: Float) -> [Float] {
        (0..<dim).map { seed + Float($0) * 0.001 }
    }

    func testInsertFetchAllRoundTrip() {
        let v1 = vector(seed: 1)
        let v2 = vector(seed: 2)
        store.insert(id: "a", vector: v1)
        store.insert(id: "b", vector: v2)

        let all = store.fetchAll()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.map(\.id), ["a", "b"], "fetchAll 按插入序返回")
        XCTAssertEqual(all[0].vector, v1, "blob 往返应逐位一致")
        XCTAssertEqual(all[1].vector, v2)
    }

    func testExistingIDsAndCount() {
        XCTAssertEqual(store.count(), 0)
        XCTAssertTrue(store.existingIDs().isEmpty)

        store.insert(id: "a", vector: vector(seed: 1))
        store.insert(id: "b", vector: vector(seed: 2))
        store.insert(id: "c", vector: vector(seed: 3))

        XCTAssertEqual(store.count(), 3)
        XCTAssertEqual(store.existingIDs(), ["a", "b", "c"])
    }

    /// INSERT OR REPLACE：同 id 重插覆盖，计数不变，内容更新。
    func testInsertSameIDReplaces() {
        store.insert(id: "a", vector: vector(seed: 1))
        store.insert(id: "a", vector: vector(seed: 9))

        XCTAssertEqual(store.count(), 1)
        XCTAssertEqual(store.fetchAll().first?.vector, vector(seed: 9))
    }

    func testDelete() {
        for id in ["a", "b", "c"] { store.insert(id: id, vector: vector(seed: 1)) }
        store.delete(ids: ["b"])

        XCTAssertEqual(store.count(), 2)
        XCTAssertEqual(store.existingIDs(), ["a", "c"])
        XCTAssertEqual(store.fetchAll().map(\.id), ["a", "c"])

        // 空列表与不存在 id 都是 no-op
        store.delete(ids: [])
        store.delete(ids: ["not-exist"])
        XCTAssertEqual(store.count(), 2)
    }

    /// open() 会写入索引格式版本标记（模型/维度变更时供上层判断重建）。
    func testModelVersionMetaWrittenOnOpen() {
        XCTAssertEqual(store.metaValue("modelVersion"), EmbeddingStore.modelVersion)
    }
}
