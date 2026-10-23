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
}
