import Foundation
import SQLite3

/// Zero-dependency embedding persistence backed by the SQLite3 C API.
///
/// Table `embeddings`: localIdentifier -> 256-d Float32 vector blob.
/// All methods are called from the main actor (the scan loop), so no extra
/// synchronisation is needed; SQLite itself is opened in serialized mode.
final class EmbeddingStore {

    enum StoreError: LocalizedError {
        case openFailed(String)
        case execFailed(String)

        var errorDescription: String? {
            switch self {
            case .openFailed(let m): return "数据库打开失败：\(m)"
            case .execFailed(let m): return "数据库操作失败：\(m)"
            }
        }
    }

    private var db: OpaquePointer?
    private let dim: Int

    /// 索引格式版本：模型/维度/量化方式变化时递增；不匹配只记录日志，不强制清库。
    static let modelVersion = "eg2-256d-v1"

    init(dim: Int = EmbeddingEngine.outputDim) {
        self.dim = dim
    }

    deinit { sqlite3_close(db) }

    // MARK: - Open / schema

    func open() throws {
        guard db == nil else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("embeddings.sqlite")
        if sqlite3_open(url.path, &db) != SQLITE_OK {
            throw StoreError.openFailed(lastMessage())
        }
        try exec("""
            CREATE TABLE IF NOT EXISTS embeddings(
              id TEXT PRIMARY KEY,
              dim INTEGER NOT NULL,
              vec BLOB NOT NULL,
              created_at REAL NOT NULL
            )
            """)
        // OCR 文本索引：id -> 识别文本（空格连接），done_at 即"已跑过 OCR"标记
        try exec("""
            CREATE TABLE IF NOT EXISTS ocr(
              id TEXT PRIMARY KEY,
              text TEXT NOT NULL,
              done_at REAL NOT NULL
            )
            """)
        // 质量信号表：废片判定用（v0.3c）
        try exec("""
            CREATE TABLE IF NOT EXISTS quality(
              id TEXT PRIMARY KEY,
              blur REAL NOT NULL,
              bright_mean REAL NOT NULL,
              bright_std REAL NOT NULL,
              face_quality REAL NOT NULL,
              has_face INTEGER NOT NULL,
              done_at REAL NOT NULL
            )
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS meta(
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            )
            """)
        checkModelVersion()
    }

    /// meta.modelVersion 记录与检查：不匹配仅日志提示重建（v0.3a 不强制清库）。
    private func checkModelVersion() {
        if let found = metaValue("modelVersion") {
            if found != Self.modelVersion {
                AutoTest.log("[Store] 索引版本不匹配: 库=\(found) 当前=\(Self.modelVersion)，建议重建索引（暂不强制清库）")
            }
        } else {
            setMeta("modelVersion", Self.modelVersion)
            AutoTest.log("[Store] 索引版本标记: \(Self.modelVersion)")
        }
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? lastMessage()
            sqlite3_free(err)
            throw StoreError.execFailed(msg)
        }
    }

    private func lastMessage() -> String {
        db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }

    // MARK: - Writes

    func insert(id: String, vector: [Float]) {
        guard let db else { return }
        let sql = "INSERT OR REPLACE INTO embeddings(id, dim, vec, created_at) VALUES(?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, Int32(vector.count))
        vector.withUnsafeBufferPointer { buf in
            sqlite3_bind_blob(stmt, 3, buf.baseAddress, Int32(vector.count * MemoryLayout<Float>.size), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    func delete(ids: [String]) {
        guard let db, !ids.isEmpty else { return }
        let sql = "DELETE FROM embeddings WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for id in ids {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_step(stmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    // MARK: - Reads

    func existingIDs() -> Set<String> {
        guard let db else { return [] }
        var ids = Set<String>()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM embeddings", -1, &stmt, nil) == SQLITE_OK else { return ids }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                ids.insert(String(cString: c))
            }
        }
        return ids
    }

    func count() -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM embeddings", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// All (localIdentifier, 256-d vector) pairs, in insertion order.
    func fetchAll() -> [(id: String, vector: [Float])] {
        guard let db else { return [] }
        var out: [(String, [Float])] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, vec FROM embeddings ORDER BY rowid", -1, &stmt, nil) == SQLITE_OK else { return out }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0) else { continue }
            let id = String(cString: c)
            let n = Int(sqlite3_column_bytes(stmt, 1))
            guard n == dim * MemoryLayout<Float>.size,
                  let blob = sqlite3_column_blob(stmt, 1) else { continue }
            var vec = [Float](repeating: 0, count: dim)
            memcpy(&vec, blob, n)
            out.append((id, vec))
        }
        return out
    }

    // MARK: - OCR 索引

    func insertOcr(id: String, text: String) {
        guard let db else { return }
        let sql = "INSERT OR REPLACE INTO ocr(id, text, done_at) VALUES(?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    /// 已有 OCR 记录（含空文本——跑过即算完成，支持断点续跑/补建判断）。
    func existingOcrIDs() -> Set<String> {
        guard let db else { return [] }
        var ids = Set<String>()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM ocr", -1, &stmt, nil) == SQLITE_OK else { return ids }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { ids.insert(String(cString: c)) }
        }
        return ids
    }

    /// 全量 OCR 文本（关键词检索用）。
    func fetchAllOcr() -> [String: String] {
        guard let db else { return [:] }
        var out: [String: String] = [:]
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, text FROM ocr", -1, &stmt, nil) == SQLITE_OK else { return out }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0),
                  let t = sqlite3_column_text(stmt, 1) else { continue }
            out[String(cString: c)] = String(cString: t)
        }
        return out
    }

    /// OCR 覆盖统计：总条数 / 识别到非空文本的条数。
    func ocrCoverage() -> (total: Int, withText: Int) {
        guard let db else { return (0, 0) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*), SUM(LENGTH(TRIM(text)) > 0) FROM ocr", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return (0, 0) }
        return (Int(sqlite3_column_int(stmt, 0)), Int(sqlite3_column_int(stmt, 1)))
    }

    // MARK: - meta 表

    func metaValue(_ key: String) -> String? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    func setMeta(_ key: String, _ value: String) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_step(stmt)
    }

    // MARK: - 质量信号（废片判定用，v0.3c 新增，纯增量）

    /// 一张图的质量信号快照。
    struct QualityRecord {
        var blur: Double        // Laplacian 方差原始值（越大越清晰）
        var brightMean: Double  // 0-1 平均亮度
        var brightStd: Double   // 0-1 亮度标准差
        var faceQuality: Double // 0-1 最高人脸质量（无人脸时无意义）
        var hasFace: Bool
    }

    func insertQuality(id: String, record r: QualityRecord) {
        guard let db else { return }
        let sql = """
            INSERT OR REPLACE INTO quality(id, blur, bright_mean, bright_std, face_quality, has_face, done_at)
            VALUES(?, ?, ?, ?, ?, ?, ?)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_double(stmt, 2, r.blur)
        sqlite3_bind_double(stmt, 3, r.brightMean)
        sqlite3_bind_double(stmt, 4, r.brightStd)
        sqlite3_bind_double(stmt, 5, r.faceQuality)
        sqlite3_bind_int(stmt, 6, r.hasFace ? 1 : 0)
        sqlite3_bind_double(stmt, 7, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    /// 已跑过质量信号的 id 集合（断点续跑/补建判断）。
    func existingQualityIDs() -> Set<String> {
        guard let db else { return [] }
        var ids = Set<String>()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM quality", -1, &stmt, nil) == SQLITE_OK else { return ids }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { ids.insert(String(cString: c)) }
        }
        return ids
    }

    /// 全量质量信号。
    func fetchAllQuality() -> [String: QualityRecord] {
        guard let db else { return [:] }
        var out: [String: QualityRecord] = [:]
        var stmt: OpaquePointer?
        let sql = "SELECT id, blur, bright_mean, bright_std, face_quality, has_face FROM quality"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return out }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0) else { continue }
            out[String(cString: c)] = QualityRecord(
                blur: sqlite3_column_double(stmt, 1),
                brightMean: sqlite3_column_double(stmt, 2),
                brightStd: sqlite3_column_double(stmt, 3),
                faceQuality: sqlite3_column_double(stmt, 4),
                hasFace: sqlite3_column_int(stmt, 5) != 0
            )
        }
        return out
    }

    /// 全表清除（embeddings + ocr + quality）。v0.3c 废片删除用；原有 delete(ids:) 不动。
    func deleteEverywhere(ids: [String]) {
        guard let db, !ids.isEmpty else { return }
        for table in ["embeddings", "ocr", "quality"] {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM \(table) WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { continue }
            sqlite3_exec(db, "BEGIN", nil, nil, nil)
            for id in ids {
                sqlite3_reset(stmt)
                sqlite3_bind_text(stmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_step(stmt)
            }
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
            sqlite3_finalize(stmt)
        }
    }
}
