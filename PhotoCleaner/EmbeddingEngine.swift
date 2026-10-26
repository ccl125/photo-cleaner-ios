import Accelerate
import CoreML
import Foundation
import Tokenizers
import UIKit

/// Swift port of the validated Python pipeline (bench_embedding.py):
///
///   UIImage -> aspect-preserving resize (sides multiple of 48 px, <= 630 patches of 16 px)
///           -> RGB / 255 -> row-major [16 rows][16 cols][RGB] patches
///           -> EmbeddingGemma2Vision (function vision_70) -> image_tokens [1, 70, 512]
///           -> <bos> <|image|> tokens <image|> <eos>
///           -> EmbeddingGemma2Text (function embed_128)   -> embedding [1, 768]
///           -> MRL truncate to 256 dims -> L2 normalize
///
/// All model inputs are Float16 MLMultiArrays with fixed shapes (that is what
/// keeps the graph on the Neural Engine).
actor EmbeddingEngine {

    enum EngineError: LocalizedError {
        case notPrepared
        case imageConversionFailed
        case outputMissing(String)

        var errorDescription: String? {
            switch self {
            case .notPrepared: return "模型尚未加载"
            case .imageConversionFailed: return "图片预处理失败"
            case .outputMissing(let name): return "模型输出缺少 \(name)"
            }
        }
    }

    struct Timing: Sendable {
        var visionMs: Double = 0
        var textMs: Double = 0
        var totalMs: Double { visionMs + textMs }
    }

    struct Stats: Sendable {
        var count: Int = 0
        var totalMs: Double = 0
        var lastMs: Double = 0
        var avgMs: Double { count > 0 ? totalMs / Double(count) : 0 }
    }

    // Output dimension used by the app (MRL truncation from 768).
    static let outputDim = 256
    static let similarityThreshold: Float = 0.93

    private let budget = 70                 // vision_70
    private let patch = 16
    private let poolK = 3
    private var nPatches: Int { budget * 9 } // 630
    private let textSeq = 128               // smallest embed_S >= 70 + 4

    private var vision: MLModel?
    private var text: MLModel?
    /// [4, 512] Float16, order: BOS, BOI, EOI, EOS (pre-scaled by sqrt(512)).
    private var specialTokens: [Float16] = []
    /// [2, 1024, 768] Float16; value for patch (x, y) = table[0][x] + table[1][y].
    private var posTable: [Float16] = []

    // 文本检索（语义搜图）资产，懒加载
    private var tokenizer: (any Tokenizer)?
    private var vocabTable: VocabEmbeddingTable?
    /// 检索前缀（config.json prompts.search_query；图像侧不加前缀，query 侧加）
    static let queryPrefix = "task: search result | query: "

    private(set) var stats = Stats()

    /// 闲置释放：60 秒无推理调用则卸载两座塔 + 文本资产（约 600MB），下次调用懒加载。
    private var idleReleaseTask: Task<Void, Never>?
    private static let idleTimeoutNs: UInt64 = 60_000_000_000

    // MARK: - Loading

    func prepare() throws {
        if vision != nil, text != nil {
            touchModels()
            return
        }
        AutoTest.log("[Engine] 加载 vision 塔 …")
        vision = try ModelManager.loadModel(package: "EmbeddingGemma2Vision", function: "vision_70")
        AutoTest.log("[Engine] 加载 text 塔 …")
        text = try ModelManager.loadModel(package: "EmbeddingGemma2Text", function: "embed_128")
        specialTokens = try Self.loadF16(resource: "special_tokens", count: 4 * 512)
        posTable = try Self.loadF16(resource: "position_embeddings", count: 2 * 1024 * 768)
        AutoTest.log("[Engine] 模型就绪")
        touchModels()
    }

    /// 每次推理后刷新闲置计时；超时卸载模型。
    private func touchModels() {
        idleReleaseTask?.cancel()
        idleReleaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.idleTimeoutNs)
            guard !Task.isCancelled else { return }
            await self?.unloadModels()
        }
    }

    private func unloadModels() {
        guard vision != nil || text != nil else { return }
        vision = nil
        text = nil
        tokenizer = nil
        vocabTable = nil
        idleReleaseTask = nil
        AutoTest.log("[Engine] 闲置 60s 无推理，模型已卸载（下次调用自动重载）")
    }

    private static func loadF16(resource: String, count: Int) throws -> [Float16] {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "f16") else {
            throw EngineError.outputMissing("\(resource).f16 资源文件")
        }
        let data = try Data(contentsOf: url)
        guard data.count == count * MemoryLayout<Float16>.size else {
            throw EngineError.outputMissing("\(resource).f16 大小不符")
        }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
    }

    // MARK: - Inference

    /// Returns a 256-d L2-normalized embedding for the image.
    func embed(_ image: UIImage) throws -> (vector: [Float], timing: Timing) {
        try prepare()  // 闲置释放后的懒加载入口
        guard let vision, let text else { throw EngineError.notPrepared }

        let (rgb, w, h) = try preprocess(image) // Float [0,1], w/h multiples of 48
        let gh = h / patch, gw = w / patch
        let nReal = gh * gw
        let nTok = (gh / poolK) * (gw / poolK)

        // ---- vision inputs
        let patches = try MLMultiArray(shape: [1, nPatches, 768] as [NSNumber], dataType: .float16)
        let positions = try MLMultiArray(shape: [1, nPatches, 2] as [NSNumber], dataType: .float16)
        let posEmb = try MLMultiArray(shape: [1, nPatches, 768] as [NSNumber], dataType: .float16)
        let valid = try MLMultiArray(shape: [1, nPatches] as [NSNumber], dataType: .float16)
        let pool = try MLMultiArray(shape: [budget, nPatches] as [NSNumber], dataType: .float16)

        fillPatches(patches, rgb: rgb, w: w, gw: gw, gh: gh)
        fillPositions(positions, gw: gw, nReal: nReal)
        fillPosEmb(posEmb, gw: gw, nReal: nReal)
        fillValid(valid, nReal: nReal)
        fillPool(pool, gw: gw, gh: gh)

        var timing = Timing()
        let t0 = CFAbsoluteTimeGetCurrent()
        let vOut = try vision.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "patches": MLFeatureValue(multiArray: patches),
            "positions": MLFeatureValue(multiArray: positions),
            "position_embeddings": MLFeatureValue(multiArray: posEmb),
            "valid": MLFeatureValue(multiArray: valid),
            "pool": MLFeatureValue(multiArray: pool),
        ]))
        timing.visionMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        guard let tokens = vOut.featureValue(for: "image_tokens")?.multiArrayValue else {
            throw EngineError.outputMissing("image_tokens")
        }

        // ---- text tower: <bos> <|image|> [tokens] <image|> <eos>
        let seq = try MLMultiArray(shape: [1, textSeq, 512] as [NSNumber], dataType: .float16)
        let mask = try MLMultiArray(shape: [1, textSeq] as [NSNumber], dataType: .float16)
        fillTextInputs(seq: seq, mask: mask, tokens: tokens, nTok: nTok)

        let t1 = CFAbsoluteTimeGetCurrent()
        let tOut = try text.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "inputs_embeds": MLFeatureValue(multiArray: seq),
            "attention_mask": MLFeatureValue(multiArray: mask),
        ]))
        timing.textMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000

        guard let embArr = tOut.featureValue(for: "embedding")?.multiArrayValue else {
            throw EngineError.outputMissing("embedding")
        }

        // ---- MRL truncate to 256 + L2 normalize
        let embPtr = embArr.dataPointer.bindMemory(to: Float.self, capacity: 768)
        var vec = [Float](repeating: 0, count: Self.outputDim)
        for i in 0..<Self.outputDim { vec[i] = embPtr[i] }
        var norm: Float = 0
        vDSP_svesq(vec, 1, &norm, vDSP_Length(vec.count))
        let inv = 1.0 / (norm.squareRoot() + 1e-12)
        vDSP_vsmul(vec, 1, [inv], &vec, 1, vDSP_Length(vec.count))

        stats.count += 1
        stats.lastMs = timing.totalMs
        stats.totalMs += timing.totalMs
        return (vec, timing)
    }

    // MARK: - Preprocessing (mirrors bench_embedding.py)

    private func targetSize(_ W: Int, _ H: Int) -> (Int, Int) {
        let scale = min(1.0, (Double(nPatches * patch * patch) / Double(W * H)).squareRoot())
        var w = max(48, Int((Double(W) * scale / 48).rounded()) * 48)
        var h = max(48, Int((Double(H) * scale / 48).rounded()) * 48)
        while (w / patch) * (h / patch) > nPatches {
            if w >= h { w -= 48 } else { h -= 48 }
        }
        return (w, h)
    }

    /// Orientation-correct resize + RGBA extraction -> Float RGB in [0, 1].
    private func preprocess(_ image: UIImage) throws -> ([Float], Int, Int) {
        let W0 = image.cgImage?.width ?? Int(image.size.width)
        let H0 = image.cgImage?.height ?? Int(image.size.height)
        guard W0 > 0, H0 > 0 else { throw EngineError.imageConversionFailed }
        let (w, h) = targetSize(W0, H0)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        guard let cg = rendered.cgImage else { throw EngineError.imageConversionFailed }

        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &bytes, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw EngineError.imageConversionFailed }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var rgb = [Float](repeating: 0, count: w * h * 3)
        rgb.withUnsafeMutableBufferPointer { dst in
            for i in 0..<(w * h) {
                dst[3 * i] = Float(bytes[4 * i]) / 255
                dst[3 * i + 1] = Float(bytes[4 * i + 1]) / 255
                dst[3 * i + 2] = Float(bytes[4 * i + 2]) / 255
            }
        }
        return (rgb, w, h)
    }

    // MARK: - Tensor fills

    /// patches[1, N, 768]: patch (r, c) flattened as [16 rows][16 cols][RGB]; zero padding.
    private func fillPatches(_ arr: MLMultiArray, rgb: [Float], w: Int, gw: Int, gh: Int) {
        let p = arr.dataPointer.bindMemory(to: Float16.self, capacity: nPatches * 768)
        for k in 0..<nPatches {
            let r = k / gw, c = k % gw
            let base = k * 768
            if r < gh {
                for i in 0..<patch {
                    let rowStart = ((r * patch + i) * w + c * patch) * 3
                    for j in 0..<patch {
                        let src = rowStart + j * 3
                        let dst = base + (i * patch + j) * 3
                        p[dst] = Float16(rgb[src])
                        p[dst + 1] = Float16(rgb[src + 1])
                        p[dst + 2] = Float16(rgb[src + 2])
                    }
                }
            } else {
                for d in 0..<768 { p[base + d] = 0 }
            }
        }
    }

    /// positions[1, N, 2]: (x, y) patch coords; -1 for padding.
    private func fillPositions(_ arr: MLMultiArray, gw: Int, nReal: Int) {
        let p = arr.dataPointer.bindMemory(to: Float16.self, capacity: nPatches * 2)
        for k in 0..<nPatches {
            if k < nReal {
                p[2 * k] = Float16(k % gw)     // x = column
                p[2 * k + 1] = Float16(k / gw) // y = row
            } else {
                p[2 * k] = -1
                p[2 * k + 1] = -1
            }
        }
    }

    /// position_embeddings[1, N, 768] = table[0][x] + table[1][y]; zero padding.
    private func fillPosEmb(_ arr: MLMultiArray, gw: Int, nReal: Int) {
        let p = arr.dataPointer.bindMemory(to: Float16.self, capacity: nPatches * 768)
        posTable.withUnsafeBufferPointer { table in
            let t = table.baseAddress!
            for k in 0..<nPatches {
                let base = k * 768
                if k < nReal {
                    let x = k % gw, y = k / gw
                    let xOff = x * 768
                    let yOff = (1024 + y) * 768
                    for d in 0..<768 {
                        p[base + d] = Float16(Float(t[xOff + d]) + Float(t[yOff + d]))
                    }
                } else {
                    for d in 0..<768 { p[base + d] = 0 }
                }
            }
        }
    }

    private func fillValid(_ arr: MLMultiArray, nReal: Int) {
        let p = arr.dataPointer.bindMemory(to: Float16.self, capacity: nPatches)
        for k in 0..<nPatches { p[k] = k < nReal ? 1 : 0 }
    }

    /// pool[T, N]: token t averages its 3x3 patch group (weight 1/9).
    private func fillPool(_ arr: MLMultiArray, gw: Int, gh: Int) {
        let p = arr.dataPointer.bindMemory(to: Float16.self, capacity: budget * nPatches)
        let w9 = Float16(1.0 / 9.0)
        memset(p, 0, budget * nPatches * MemoryLayout<Float16>.size)
        let th = gh / poolK, tw = gw / poolK
        for tr in 0..<th {
            for tc in 0..<tw {
                let t = tr * tw + tc
                for i in 0..<poolK {
                    for j in 0..<poolK {
                        p[t * nPatches + (poolK * tr + i) * gw + poolK * tc + j] = w9
                    }
                }
            }
        }
    }

    /// inputs_embeds[1, 128, 512] + attention_mask[1, 128].
    private func fillTextInputs(seq: MLMultiArray, mask: MLMultiArray, tokens: MLMultiArray, nTok: Int) {
        let s = seq.dataPointer.bindMemory(to: Float16.self, capacity: textSeq * 512)
        memset(s, 0, textSeq * 512 * MemoryLayout<Float16>.size)
        specialTokens.withUnsafeBufferPointer { sp in
            let t = sp.baseAddress!
            for d in 0..<512 {
                s[d] = t[d]                       // <bos>
                s[512 + d] = t[512 + d]           // <|image|>
            }
        }
        // image tokens (Float16, [1, 70, 512]) starting at row 2
        let tok = tokens.dataPointer.bindMemory(to: Float16.self, capacity: budget * 512)
        for r in 0..<nTok {
            for d in 0..<512 { s[(2 + r) * 512 + d] = tok[r * 512 + d] }
        }
        specialTokens.withUnsafeBufferPointer { sp in
            let t = sp.baseAddress!
            for d in 0..<512 {
                s[(2 + nTok) * 512 + d] = t[2 * 512 + d]     // <image|>
                s[(3 + nTok) * 512 + d] = t[3 * 512 + d]     // <eos>
            }
        }
        let m = mask.dataPointer.bindMemory(to: Float16.self, capacity: textSeq)
        for i in 0..<textSeq { m[i] = i < nTok + 4 ? 1 : 0 }
    }
}

// MARK: - 文本检索（语义搜图）

/// 词表 embedding 的 int8 量化表（Models/vocab_embeddings_i8.bin，135MB，mmap 读取）。
/// 布局: "EGV1" | rows u32 | dim u32 | scales[rows] fp32 | data[rows×dim] int8。
/// 导出时已预乘 √512，反量化值可直接进文本塔；bos/eos 等所有 token 行走同一张表。
final class VocabEmbeddingTable: @unchecked Sendable {
    let rows: Int
    let dim: Int
    private let data: Data
    private let scalesOffset = 12
    private let dataOffset: Int

    init(url: URL) throws {
        let d = try Data(contentsOf: url, options: .mappedIfSafe)
        guard d.count > 12, d.prefix(4).elementsEqual([0x45, 0x47, 0x56, 0x31]) else { // "EGV1"
            throw EmbeddingEngine.EngineError.outputMissing("vocab_embeddings_i8.bin 格式错误")
        }
        rows = d.withUnsafeBytes { Int($0.load(fromByteOffset: 4, as: UInt32.self)) }
        dim = d.withUnsafeBytes { Int($0.load(fromByteOffset: 8, as: UInt32.self)) }
        dataOffset = scalesOffset + rows * MemoryLayout<Float>.size
        guard d.count == dataOffset + rows * dim else {
            throw EmbeddingEngine.EngineError.outputMissing("vocab_embeddings_i8.bin 大小不符")
        }
        data = d
    }

    /// 反量化第 id 行 → [Float]（dim 维，已含 √512 缩放）
    func row(_ id: Int) -> [Float] {
        precondition(id >= 0 && id < rows)
        var out = [Float](repeating: 0, count: dim)
        data.withUnsafeBytes { raw in
            let scale = raw.load(fromByteOffset: scalesOffset + id * MemoryLayout<Float>.size, as: Float.self)
            let q = raw.bindMemory(to: Int8.self)
            let base = dataOffset + id * dim
            for i in 0..<dim { out[i] = Float(q[base + i]) * scale }
        }
        return out
    }
}

extension EmbeddingEngine {

    /// 文本 → 256 维 embedding（与图像同向量空间）。自动加检索前缀，超长按 128 token 截断。
    func embedText(_ query: String) async throws -> [Float] {
        try prepare()  // 闲置释放后的懒加载入口（同时刷新闲置计时）
        guard let text else { throw EngineError.notPrepared }
        if tokenizer == nil || vocabTable == nil { try await loadTextAssets() }
        guard let tokenizer, let vocab = vocabTable else {
            throw EngineError.outputMissing("文本检索资产")
        }

        // tokenizer.json 的 post-processor 会自动拼 <bos>/<eos>
        var ids = tokenizer.encode(text: Self.queryPrefix + query)
        if ids.count > textSeq { ids = Array(ids.prefix(textSeq)) }

        let seq = try MLMultiArray(shape: [1, textSeq, 512] as [NSNumber], dataType: .float16)
        let mask = try MLMultiArray(shape: [1, textSeq] as [NSNumber], dataType: .float16)
        let s = seq.dataPointer.bindMemory(to: Float16.self, capacity: textSeq * 512)
        memset(s, 0, textSeq * 512 * MemoryLayout<Float16>.size)
        for (i, id) in ids.enumerated() {
            let row = vocab.row(id)
            for d in 0..<512 { s[i * 512 + d] = Float16(row[d]) }
        }
        let m = mask.dataPointer.bindMemory(to: Float16.self, capacity: textSeq)
        for i in 0..<textSeq { m[i] = i < ids.count ? 1 : 0 }

        let t0 = CFAbsoluteTimeGetCurrent()
        let out = try await text.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "inputs_embeds": MLFeatureValue(multiArray: seq),
            "attention_mask": MLFeatureValue(multiArray: mask),
        ]))
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        guard let embArr = out.featureValue(for: "embedding")?.multiArrayValue else {
            throw EngineError.outputMissing("embedding")
        }
        let embPtr = embArr.dataPointer.bindMemory(to: Float.self, capacity: 768)
        var vec = [Float](repeating: 0, count: Self.outputDim)
        for i in 0..<Self.outputDim { vec[i] = embPtr[i] }
        var norm: Float = 0
        vDSP_svesq(vec, 1, &norm, vDSP_Length(vec.count))
        let inv = 1.0 / (norm.squareRoot() + 1e-12)
        vDSP_vsmul(vec, 1, [inv], &vec, 1, vDSP_Length(vec.count))

        AutoTest.log("[Engine] embedText \"\(query)\" tokens=\(ids.count) \(String(format: "%.0f", ms))ms")
        return vec
    }

    private func loadTextAssets() async throws {
        if tokenizer == nil {
            guard let folder = Bundle.main.resourceURL?
                .appendingPathComponent("Tokenizer", isDirectory: true) else {
                throw EngineError.outputMissing("bundle 资源目录")
            }
            AutoTest.log("[Engine] 加载 tokenizer …")
            tokenizer = try await AutoTokenizer.from(modelFolder: folder)
        }
        if vocabTable == nil {
            guard let url = Bundle.main.url(forResource: "vocab_embeddings_i8",
                                            withExtension: "bin", subdirectory: "Models") else {
                throw EngineError.outputMissing("vocab_embeddings_i8.bin（Debug 注入，确认 ModelAssets 存在）")
            }
            AutoTest.log("[Engine] 加载词表 embedding 表 …")
            vocabTable = try VocabEmbeddingTable(url: url)
        }
    }
}
