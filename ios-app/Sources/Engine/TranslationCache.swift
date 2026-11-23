import Foundation
import SQLite3

private let SQLITE_TRANSIENT_PTR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// High-speed offline SQLite translation cache (<3ms lookups) + per-game JSON Glossary manager.
public actor TranslationCache {

    private var db: OpaquePointer?
    private let dbURL: URL
    private let glossariesDir: URL
    private var glossaryMemoryCache: [String: [String: String]] = [:]

    public init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.dbURL = docs.appendingPathComponent("ps5_translations_cache.sqlite")
        self.glossariesDir = docs.appendingPathComponent("glossaries", isDirectory: true)

        try? FileManager.default.createDirectory(at: glossariesDir, withIntermediateDirectories: true)
        self.db = Self.openDatabase(at: dbURL)
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - SQLite Initialization

    private static func openDatabase(at url: URL) -> OpaquePointer? {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            return nil
        }

        let setupSQL = """
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        CREATE TABLE IF NOT EXISTS translations (
            title_id TEXT NOT NULL,
            source_norm TEXT NOT NULL,
            arabic_text TEXT NOT NULL,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY (title_id, source_norm)
        );
        """
        sqlite3_exec(handle, setupSQL, nil, nil, nil)
        return handle
    }

    // MARK: - Text Normalization

    public nonisolated static func normalize(_ english: String) -> String {
        english
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private nonisolated static func sanitizeTitleID(_ titleID: String) -> String {
        let cleaned = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let allowed = cleaned.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        return allowed.isEmpty ? "GLOBAL" : allowed
    }

    // MARK: - Cache Operations

    public func lookup(titleID: String, englishText: String) -> String? {
        guard let db else { return nil }
        let tid = Self.sanitizeTitleID(titleID)
        let norm = Self.normalize(englishText)
        guard !norm.isEmpty else { return nil }

        let sql = "SELECT arabic_text FROM translations WHERE title_id = ? AND source_norm = ? LIMIT 1;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, tid, -1, SQLITE_TRANSIENT_PTR)
        sqlite3_bind_text(stmt, 2, norm, -1, SQLITE_TRANSIENT_PTR)

        if sqlite3_step(stmt) == SQLITE_ROW, let cStr = sqlite3_column_text(stmt, 0) {
            return String(cString: cStr)
        }
        return nil
    }

    public func store(titleID: String, englishText: String, arabicText: String) {
        guard let db else { return }
        let tid = Self.sanitizeTitleID(titleID)
        let norm = Self.normalize(englishText)
        let ar = arabicText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !norm.isEmpty, !ar.isEmpty else { return }

        let sql = """
        INSERT INTO translations (title_id, source_norm, arabic_text, updated_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(title_id, source_norm) DO UPDATE SET
            arabic_text = excluded.arabic_text,
            updated_at = excluded.updated_at;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, tid, -1, SQLITE_TRANSIENT_PTR)
        sqlite3_bind_text(stmt, 2, norm, -1, SQLITE_TRANSIENT_PTR)
        sqlite3_bind_text(stmt, 3, ar, -1, SQLITE_TRANSIENT_PTR)
        sqlite3_bind_int64(stmt, 4, Int64(Date().timeIntervalSince1970))
        sqlite3_step(stmt)
    }

    public func clearCache(for titleID: String? = nil) {
        guard let db else { return }
        if let titleID {
            let tid = Self.sanitizeTitleID(titleID)
            let sql = "DELETE FROM translations WHERE title_id = ?;"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, tid, -1, SQLITE_TRANSIENT_PTR)
                sqlite3_step(stmt)
            }
        } else {
            sqlite3_exec(db, "DELETE FROM translations;", nil, nil, nil)
        }
    }

    public func totalCachedEntries() -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM translations;", -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    // MARK: - Per-Game JSON Glossary Management

    private func glossaryURL(for titleID: String) -> URL {
        glossariesDir.appendingPathComponent("\(Self.sanitizeTitleID(titleID)).json")
    }

    public func loadGlossary(for titleID: String) -> [String: String] {
        let tid = Self.sanitizeTitleID(titleID)
        if let cached = glossaryMemoryCache[tid] {
            return cached
        }
        let url = glossaryURL(for: tid)
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            glossaryMemoryCache[tid] = [:]
            return [:]
        }
        glossaryMemoryCache[tid] = dict
        return dict
    }

    public func saveGlossary(_ glossary: [String: String], for titleID: String) {
        let tid = Self.sanitizeTitleID(titleID)
        glossaryMemoryCache[tid] = glossary
        let url = glossaryURL(for: tid)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(glossary) {
            try? data.write(to: url, options: .atomic)
        }
    }

    public func upsertGlossaryTerm(english: String, arabic: String, for titleID: String) {
        let en = english.trimmingCharacters(in: .whitespacesAndNewlines)
        let ar = arabic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !en.isEmpty, !ar.isEmpty else { return }
        var dict = loadGlossary(for: titleID)
        dict[en] = ar
        saveGlossary(dict, for: titleID)
    }

    public func removeGlossaryTerm(english: String, for titleID: String) {
        var dict = loadGlossary(for: titleID)
        dict.removeValue(forKey: english)
        saveGlossary(dict, for: titleID)
    }

    public func listAvailableGlossaryTitleIDs() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: glossariesDir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }
}
