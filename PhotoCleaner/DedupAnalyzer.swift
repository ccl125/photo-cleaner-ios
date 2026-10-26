import Accelerate
import Foundation

/// 全量向量两两 cosine（向量已 L2 归一化，点积即 cosine），锚点星型聚类。
///
/// 为什么不用 union-find：链式传递（A~B, B~C, C~D…）会把几千张互不相似的照片
/// 串成一组（真机实测 4,594 张里最大组 3,357 张）。星型聚类只允许直接与锚点
/// 相似的照片入组，组内凝聚度有保证（实测 min ≥ 0.86）。
///
/// 双阈值分档：
///   - 重复组 duplicate：> 0.97（近重复，可安全建议删除）
///   - 相似组 similar：0.90–0.97（同主题/连拍，只浏览不自动建议删除）
///   已进入重复组的照片不再参与相似组。
/// 内存 O(n)：分块 sgemm 只统计度数，锚点行用 sgemv 按需重算。
enum DedupAnalyzer {

    enum Tier: Sendable {
        case duplicate
        case similar
    }

    struct Group: Sendable {
        var tier: Tier
        var assetIDs: [String]
    }

    static let duplicateThreshold: Float = 0.97
    static let similarThreshold: Float = 0.90
    private static let blockRows = 256

    static func findGroups(store: EmbeddingStore,
                           progress: (@Sendable (Double) -> Void)? = nil) -> [Group] {
        let all = store.fetchAll()
        let n = all.count
        guard n > 1 else { return [] }
        let dim = EmbeddingEngine.outputDim

        let t0 = CFAbsoluteTimeGetCurrent()
        AutoTest.log("[Analyze] findGroups 开始: n=\(n), dim=\(dim)")

        var flat = [Float]()
        flat.reserveCapacity(n * dim)
        for (_, v) in all { flat.append(contentsOf: v) }

        // ---- Pass 1：分块 sgemm，只统计每个向量在两档上的度数
        var degDup = [Int](repeating: 0, count: n)
        var degSim = [Int](repeating: 0, count: n)
        var scoreBlock = [Float](repeating: 0, count: blockRows * n)

        flat.withUnsafeBufferPointer { mat in
            guard let base = mat.baseAddress else { return }
            var row0 = 0
            while row0 < n {
                let rows = min(blockRows, n - row0)
                scoreBlock.withUnsafeMutableBufferPointer { c in
                    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                                Int32(rows), Int32(n), Int32(dim),
                                1.0, base + row0 * dim, Int32(dim),
                                base, Int32(dim),
                                0.0, c.baseAddress!, Int32(n))
                }
                scoreBlock.withUnsafeBufferPointer { s in
                    guard let sb = s.baseAddress else { return }
                    for r in 0..<rows {
                        let i = row0 + r
                        let rowPtr = sb + r * n
                        var dd = 0, ds = 0
                        var j = i + 1
                        // 单次遍历同时累计两侧度数（矩阵对称，只看上三角）
                        while j < n {
                            let score = rowPtr[j]
                            if score > duplicateThreshold { dd += 1; degDup[j] += 1 }
                            else if score > similarThreshold { ds += 1; degSim[j] += 1 }
                            j += 1
                        }
                        degDup[i] += dd
                        degSim[i] += ds
                    }
                }
                row0 += rows
                let p = Double(row0) / Double(n) * 0.7   // pass1 占 70% 进度
                AutoTest.log("[Analyze] 分组进度 \(Int((p * 100).rounded()))%")
                progress?(p)
            }
        }

        // ---- Pass 2：按度数降序选锚点，sgemv 重算锚点行，星型聚类
        // 重复组优先；重复组成员不再参与相似组。
        func starGroups(lo: Float, hi: Float, degrees: [Int],
                        excluded: inout [Bool], label: String) -> [[Int]] {
            var order = Array(0..<n).filter { degrees[$0] > 0 && !excluded[$0] }
            order.sort { degrees[$0] > degrees[$1] }
            var groups: [[Int]] = []
            var row = [Float](repeating: 0, count: n)
            var done = 0
            for a in order {
                if excluded[a] { continue }
                // 重算锚点与全库的相似度行
                flat.withUnsafeBufferPointer { mat in
                    guard let base = mat.baseAddress else { return }
                    row.withUnsafeMutableBufferPointer { r in
                        cblas_sgemv(CblasRowMajor, CblasNoTrans,
                                    Int32(n), Int32(dim), 1.0,
                                    base, Int32(dim),
                                    base + a * dim, 1, 0.0, r.baseAddress!, 1)
                    }
                }
                var members: [Int] = []
                for j in 0..<n where j != a && !excluded[j] {
                    let s = row[j]
                    if s > lo && s <= hi { members.append(j) }
                }
                guard !members.isEmpty else { continue }
                groups.append([a] + members)
                excluded[a] = true
                for j in members { excluded[j] = true }
                done += 1
                if done % 20 == 0 {
                    AutoTest.log("[Analyze] \(label) 聚类进行中，已 \(done) 组")
                }
            }
            return groups
        }

        var excluded = [Bool](repeating: false, count: n)
        let dupGroups = starGroups(lo: duplicateThreshold, hi: Float.greatestFiniteMagnitude,
                                   degrees: degDup, excluded: &excluded, label: "重复档")
        progress?(0.85)
        let simGroups = starGroups(lo: similarThreshold, hi: duplicateThreshold,
                                   degrees: degSim, excluded: &excluded, label: "相似档")

        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        AutoTest.log("[Analyze] findGroups 完成: n=\(n), 重复组 \(dupGroups.count), 相似组 \(simGroups.count), 耗时 \(String(format: "%.1f", elapsed))s")
        progress?(1.0)

        let ids = all.map(\.id)
        return dupGroups.map { Group(tier: .duplicate, assetIDs: $0.map { ids[$0] }) }
            .sorted { $0.assetIDs.count > $1.assetIDs.count }
            + simGroups.map { Group(tier: .similar, assetIDs: $0.map { ids[$0] }) }
            .sorted { $0.assetIDs.count > $1.assetIDs.count }
    }
}
