import Accelerate
import Foundation

/// 语义搜图 + OCR 关键词混合检索（参考 DigUp 双通道设计：
/// 向量语义通道记不住的精确串——发票号/快递单号/URL——走 OCR 文本子串匹配加分）。
///
/// 向量均已 L2 归一化，cosine = 点积；4,594 条 × 256 维暴力扫是毫秒级。
enum SemanticSearch {

    struct Hit: Sendable {
        let id: String            // PHAsset localIdentifier
        let score: Float          // 合并后的分数（语义分 + 关键词加分）
        let keywordMatched: Bool  // OCR 文本命中
    }

    /// 关键词命中加分：精确串特征（含数字/单号/URL 片段格式）权重更高。
    static func keywordBoost(for query: String) -> Float {
        let hasDigit = query.contains(where: \.isNumber)
        let exactLike = query.range(of: #"^[A-Za-z0-9:./#_\-]{4,}$"#,
                                    options: .regularExpression) != nil
        return (hasDigit || exactLike) ? 0.30 : 0.15
    }

    /// 关键词项：整串（去空格）+ 空格拆分词，全小写。中文整串子串匹配即可。
    static func keywordTerms(_ query: String) -> [String] {
        let lower = query.lowercased()
        var terms = [lower.replacingOccurrences(of: " ", with: "")]
        terms += lower.split(separator: " ").map(String.init)
        return Array(Set(terms.filter { !$0.isEmpty }))
    }

    final class VectorIndex: @unchecked Sendable {
        static let shared = VectorIndex()

        private var ids: [String] = []
        private var matrix: [Float] = []          // n x 256，行主序
        private var ocrTexts: [String: String] = [:]  // 小写后的 OCR 文本
        private(set) var count = 0
        private var ocrCount = 0

        /// reload 与 topK 都持锁：快速输入时并发搜索任务会撞 reload 重分配 matrix，
        /// 不持锁则 sgemv 可能在读已释放的旧 buffer（use-after-free）。
        private let lock = NSLock()

        func reloadIfNeeded(store: EmbeddingStore) {
            lock.lock()
            defer { lock.unlock() }
            let n = store.count()
            let ocrN = store.ocrCoverage().total
            guard n != count || ocrN != ocrCount else { return }
            let all = store.fetchAll()
            ids = all.map(\.id)
            matrix = all.flatMap(\.vector)
            count = n
            // OCR 文本只保留有向量的 id（删除后 ocr 表可能有残留；正常路径已三清，这里是兜底）
            let validIDs = Set(all.map(\.id))
            ocrTexts = store.fetchAllOcr()
                .filter { validIDs.contains($0.key) }
                .mapValues { $0.lowercased() }
            ocrCount = ocrN
            AutoTest.log("[Search] 向量索引重建: \(n) 条向量，\(ocrN) 条 OCR")
        }

        /// 纯语义 Top-K（保留给无 query 文本的场景）。
        func topK(query: [Float], k: Int) -> [Hit] {
            hybridTopK(queryVector: query, queryText: "", k: k)
        }

        /// 混合检索：cosine 语义分 + OCR 关键词命中加分，按合并分降序。
        func hybridTopK(queryVector: [Float], queryText: String, k: Int) -> [Hit] {
            lock.lock()
            defer { lock.unlock() }
            guard count > 0, queryVector.count == EmbeddingEngine.outputDim else { return [] }
            var scores = [Float](repeating: 0, count: count)
            matrix.withUnsafeBufferPointer { m in
                queryVector.withUnsafeBufferPointer { q in
                    scores.withUnsafeMutableBufferPointer { s in
                        cblas_sgemv(CblasRowMajor, CblasNoTrans,
                                    Int32(count), Int32(EmbeddingEngine.outputDim), 1.0,
                                    m.baseAddress!, Int32(EmbeddingEngine.outputDim),
                                    q.baseAddress!, 1, 0.0, s.baseAddress!, 1)
                    }
                }
            }

            // 关键词通道：子串命中即加分
            var kwHit = Set<String>()
            let terms = SemanticSearch.keywordTerms(queryText)
            if !terms.isEmpty {
                let boost = SemanticSearch.keywordBoost(for: queryText)
                for (i, id) in ids.enumerated() {
                    guard let text = ocrTexts[id], !text.isEmpty else { continue }
                    if terms.contains(where: { text.contains($0) }) {
                        kwHit.insert(id)
                        scores[i] += boost
                    }
                }
                if !kwHit.isEmpty {
                    AutoTest.log("[Search] \"\(queryText)\" 关键词命中 \(kwHit.count) 条（boost +\(boost)）")
                }
            }

            let idx = Array(0..<count).sorted { scores[$0] > scores[$1] }
            return idx.prefix(min(k, count)).map {
                Hit(id: ids[$0], score: scores[$0], keywordMatched: kwHit.contains(ids[$0]))
            }
        }
    }
}
