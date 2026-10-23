import Accelerate
import Foundation

/// 全量向量两两 cosine（向量已 L2 归一化，点积即 cosine），union-find 连通分组。
/// 双阈值分档，同一次得分计算里顺带完成：
///   - 重复组 duplicate：> 0.93（近重复，可直接清理）
///   - 相似组 similar：0.80–0.93（同主题/连拍，人工优选）
/// 同一对只归到最高命中的档（两条边集互斥，各自做连通分组）。
///
/// 性能：分块 cblas_sgemm（每次 256 行查询向量 x 全库矩阵，Accelerate 多核并行），
/// 比逐行 sgemv 快一个数量级；得分块内存固定 256 x n（1 万张约 10MB）。
/// 遍历时只算上三角（j > i）。进度经 progress 回调逐块上报（后台线程触发）。
enum DedupAnalyzer {

    enum Tier: Sendable {
        case duplicate
        case similar
    }

    struct Group: Sendable {
        var tier: Tier
        var assetIDs: [String]
    }

    static let duplicateThreshold: Float = EmbeddingEngine.similarityThreshold // 0.93，勿动
    static let similarThreshold: Float = 0.80
    private static let blockRows = 256

    static func findGroups(store: EmbeddingStore,
                           progress: (@Sendable (Double) -> Void)? = nil) -> [Group] {
        let all = store.fetchAll()
        let n = all.count
        guard n > 1 else { return [] }
        let dim = EmbeddingEngine.outputDim

        let t0 = CFAbsoluteTimeGetCurrent()
        AutoTest.log("[Analyze] findGroups 开始: n=\(n), dim=\(dim), 块大小=\(blockRows)")

        var flat = [Float]()
        flat.reserveCapacity(n * dim)
        for (_, v) in all { flat.append(contentsOf: v) }

        var ufDup = UnionFind(n)
        var ufSim = UnionFind(n)
        var scoreBlock = [Float](repeating: 0, count: blockRows * n)

        flat.withUnsafeBufferPointer { mat in
            guard let base = mat.baseAddress else { return }
            var row0 = 0
            while row0 < n {
                let rows = min(blockRows, n - row0)
                // C[rows x n] = A[rows x dim] · Bᵀ，其中 B = 全库矩阵[n x dim]（行主序，转置乘）
                scoreBlock.withUnsafeMutableBufferPointer { c in
                    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                                Int32(rows), Int32(n), Int32(dim),
                                1.0, base + row0 * dim, Int32(dim),
                                base, Int32(dim),
                                0.0, c.baseAddress!, Int32(n))
                }
                // 块内阈值扫描：只算上三角 j > i（i = row0 + r 为全局行号）
                scoreBlock.withUnsafeBufferPointer { s in
                    guard let sb = s.baseAddress else { return }
                    for r in 0..<rows {
                        let i = row0 + r
                        var j = i + 1
                        let rowPtr = sb + r * n
                        while j < n {
                            let score = rowPtr[j]
                            if score > duplicateThreshold {
                                ufDup.union(i, j)            // 最高档，只进 duplicate
                            } else if score > similarThreshold {
                                ufSim.union(i, j)            // 次档，只进 similar
                            }
                            j += 1
                        }
                    }
                }
                row0 += rows
                let p = Double(row0) / Double(n)
                AutoTest.log("[Analyze] 分组进度 \(Int((p * 100).rounded()))%")
                progress?(p)
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        AutoTest.log("[Analyze] findGroups 完成: n=\(n), 耗时 \(String(format: "%.1f", elapsed))s")

        let dupGroups = components(of: ufDup, n: n, ids: all.map(\.id))
            .map { Group(tier: .duplicate, assetIDs: $0) }
            .sorted { $0.assetIDs.count > $1.assetIDs.count }
        let simGroups = components(of: ufSim, n: n, ids: all.map(\.id))
            .map { Group(tier: .similar, assetIDs: $0) }
            .sorted { $0.assetIDs.count > $1.assetIDs.count }
        return dupGroups + simGroups
    }

    /// size >= 2 的连通分量 -> assetID 数组（按向量插入顺序）。
    private static func components(of uf: UnionFind, n: Int, ids: [String]) -> [[String]] {
        var uf = uf
        var byRoot: [Int: [String]] = [:]
        for i in 0..<n {
            byRoot[uf.find(i), default: []].append(ids[i])
        }
        return byRoot.values.filter { $0.count >= 2 }
    }
}

private struct UnionFind {
    private var parent: [Int]

    init(_ n: Int) { parent = Array(0..<n) }

    mutating func find(_ x: Int) -> Int {
        if parent[x] != x { parent[x] = find(parent[x]) }
        return parent[x]
    }

    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        if ra != rb { parent[rb] = ra }
    }
}
