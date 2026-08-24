import Foundation
import SQLite3

struct ReadingHistoryEntry: Identifiable, Hashable {
    let comic: ComicSummary
    let chapterID: String
    let chapterTitle: String
    let pageIndex: Int
    let lastViewedAt: Date
    let coverRelativePath: String?

    var id: String { comic.id }
}

enum ReadingHistoryDatabaseError: LocalizedError {
    case open(path: String, code: Int32, message: String)
    case operation(name: String, code: Int32, message: String)
    case invalidData(String)

    var errorDescription: String? {
        switch self {
        case let .open(path, code, message):
            "无法打开阅读历史数据库 \(path) (SQLite \(code)): \(message)"
        case let .operation(name, code, message):
            "阅读历史操作“\(name)”失败 (SQLite \(code)): \(message)"
        case let .invalidData(message):
            "阅读历史数据无效：\(message)"
        }
    }
}

/// A normalized SQLite index stored in the same user-visible `JMComic.db` as
/// downloads and favorites. It owns a separate FULLMUTEX connection so history
/// writes cannot block UI state, while WAL coordinates safely with other stores.
final class ReadingHistoryDatabase: @unchecked Sendable {
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let lock = NSLock()
    private var database: OpaquePointer?

    init(databaseURL: URL) throws {
        let parent = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )

        var handle: OpaquePointer?
        let result = databaseURL.path.withCString {
            sqlite3_open_v2($0, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        }
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close_v2(handle) }
            throw ReadingHistoryDatabaseError.open(path: databaseURL.path, code: result, message: message)
        }
        database = handle

        do {
            try execute("PRAGMA foreign_keys = ON", name: "启用历史外键")
            try execute("PRAGMA journal_mode = WAL", name: "启用历史 WAL")
            try execute("PRAGMA synchronous = NORMAL", name: "设置历史同步等级")
            try execute("PRAGMA busy_timeout = 5000", name: "设置历史忙等待")
            try createSchema()
        } catch {
            sqlite3_close_v2(handle)
            database = nil
            throw error
        }
    }

    deinit {
        lock.lock()
        if let database { sqlite3_close_v2(database) }
        database = nil
        lock.unlock()
    }

    @discardableResult
    func record(
        comic: ComicSummary,
        chapter: Chapter,
        pageIndex: Int,
        at date: Date = .now,
        maximumEntries: Int = 500
    ) throws -> [String] {
        guard !comic.id.isEmpty, !chapter.id.isEmpty else {
            throw ReadingHistoryDatabaseError.invalidData("漫画 ID 和章节 ID 不能为空")
        }
        guard pageIndex >= 0, maximumEntries > 0 else {
            throw ReadingHistoryDatabaseError.invalidData("页索引必须非负且历史上限必须大于 0")
        }

        return try synchronized {
            try transaction {
                let upsert = try prepare(
                    """
                    INSERT INTO reading_history
                        (comic_id, name, chapter_id, chapter_title, page_index, first_viewed_at, last_viewed_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(comic_id) DO UPDATE SET
                        name = excluded.name,
                        chapter_id = excluded.chapter_id,
                        chapter_title = excluded.chapter_title,
                        page_index = excluded.page_index,
                        last_viewed_at = excluded.last_viewed_at
                    """,
                    name: "保存最近阅读"
                )
                defer { sqlite3_finalize(upsert) }
                try bind(comic.id, at: 1, in: upsert, name: "保存最近阅读")
                try bind(comic.name, at: 2, in: upsert, name: "保存最近阅读")
                try bind(chapter.id, at: 3, in: upsert, name: "保存最近阅读")
                try bind(chapter.title, at: 4, in: upsert, name: "保存最近阅读")
                try bind(pageIndex, at: 5, in: upsert, name: "保存最近阅读")
                try bind(date.timeIntervalSince1970, at: 6, in: upsert, name: "保存最近阅读")
                try bind(date.timeIntervalSince1970, at: 7, in: upsert, name: "保存最近阅读")
                try stepDone(upsert, name: "保存最近阅读")

                try replaceNames(
                    comicID: comic.id,
                    values: comic.authors,
                    dictionaryTable: "history_authors",
                    junctionTable: "reading_history_authors",
                    foreignKey: "author_id",
                    operation: "保存阅读历史作者"
                )
                try replaceNames(
                    comicID: comic.id,
                    values: comic.tags,
                    dictionaryTable: "history_tags",
                    junctionTable: "reading_history_tags",
                    foreignKey: "tag_id",
                    operation: "保存阅读历史标签"
                )

                let evictedCoverPaths = try coverRelativePathsForTrim(
                    maximumEntries: maximumEntries
                )
                let trim = try prepare(
                    """
                    DELETE FROM reading_history
                    WHERE comic_id IN (
                        SELECT comic_id FROM reading_history
                        ORDER BY last_viewed_at DESC, comic_id
                        LIMIT -1 OFFSET ?
                    )
                    """,
                    name: "限制阅读历史数量"
                )
                defer { sqlite3_finalize(trim) }
                try bind(maximumEntries, at: 1, in: trim, name: "限制阅读历史数量")
                try stepDone(trim, name: "限制阅读历史数量")
                try cleanupOrphanNames()
                return evictedCoverPaths
            }
        }
    }

    func page(offset: Int, limit: Int) throws -> [ReadingHistoryEntry] {
        guard offset >= 0, limit > 0, limit <= 200 else {
            throw ReadingHistoryDatabaseError.invalidData("offset 必须非负，limit 必须在 1...200")
        }
        return try synchronized {
            try transaction(begin: "BEGIN DEFERRED") {
                struct Row {
                    let id: String
                    let name: String
                    let chapterID: String
                    let chapterTitle: String
                    let pageIndex: Int
                    let date: Date
                    let coverRelativePath: String?
                }
                var rows: [Row] = []
                let statement = try prepare(
                    """
                    SELECT comic_id, name, chapter_id, chapter_title, page_index,
                           last_viewed_at, cover_relative_path
                    FROM reading_history
                    ORDER BY last_viewed_at DESC, comic_id
                    LIMIT ? OFFSET ?
                    """,
                    name: "分页读取阅读历史"
                )
                defer { sqlite3_finalize(statement) }
                try bind(limit, at: 1, in: statement, name: "分页读取阅读历史")
                try bind(offset, at: 2, in: statement, name: "分页读取阅读历史")
                try consumeRows(statement, name: "分页读取阅读历史") { row in
                    rows.append(Row(
                        id: text(row, 0),
                        name: text(row, 1),
                        chapterID: text(row, 2),
                        chapterTitle: text(row, 3),
                        pageIndex: Int(sqlite3_column_int64(row, 4)),
                        date: Date(timeIntervalSince1970: sqlite3_column_double(row, 5)),
                        coverRelativePath: safeCoverRelativePath(optionalText(row, 6))
                    ))
                }

                let ids = rows.map(\.id)
                let authors = try names(
                    comicIDs: ids,
                    dictionaryTable: "history_authors",
                    junctionTable: "reading_history_authors",
                    foreignKey: "author_id",
                    operation: "读取阅读历史作者"
                )
                let tags = try names(
                    comicIDs: ids,
                    dictionaryTable: "history_tags",
                    junctionTable: "reading_history_tags",
                    foreignKey: "tag_id",
                    operation: "读取阅读历史标签"
                )
                return rows.map { row in
                    ReadingHistoryEntry(
                        comic: ComicSummary(
                            id: row.id,
                            name: row.name,
                            authors: authors[row.id] ?? [],
                            tags: tags[row.id] ?? []
                        ),
                        chapterID: row.chapterID,
                        chapterTitle: row.chapterTitle,
                        pageIndex: row.pageIndex,
                        lastViewedAt: row.date,
                        coverRelativePath: row.coverRelativePath
                    )
                }
            }
        }
    }

    @discardableResult
    func clear() throws -> [String] {
        try synchronized {
            try transaction {
                let coverRelativePaths = try allCoverRelativePaths()
                try execute("DELETE FROM reading_history", name: "清空阅读历史")
                try cleanupOrphanNames()
                return coverRelativePaths
            }
        }
    }

    func coverRelativePath(comicID: String) throws -> String? {
        guard !comicID.isEmpty else {
            throw ReadingHistoryDatabaseError.invalidData("漫画 ID 不能为空")
        }
        return try synchronized {
            let statement = try prepare(
                "SELECT cover_relative_path FROM reading_history WHERE comic_id = ?",
                name: "读取阅读历史封面路径"
            )
            defer { sqlite3_finalize(statement) }
            try bind(comicID, at: 1, in: statement, name: "读取阅读历史封面路径")
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                return safeCoverRelativePath(optionalText(statement, 0))
            case SQLITE_DONE:
                return nil
            case let code:
                throw currentError(name: "读取阅读历史封面路径", code: code)
            }
        }
    }

    func setCoverRelativePath(comicID: String, relativePath: String?) throws {
        guard !comicID.isEmpty else {
            throw ReadingHistoryDatabaseError.invalidData("漫画 ID 不能为空")
        }
        if let relativePath, !JMComicCoverCacheStorage.isSafeRelativePath(relativePath) {
            throw ReadingHistoryDatabaseError.invalidData("阅读历史封面缓存路径不安全: \(relativePath)")
        }
        try synchronized {
            let statement = try prepare(
                "UPDATE reading_history SET cover_relative_path = ? WHERE comic_id = ?",
                name: "保存阅读历史封面路径"
            )
            defer { sqlite3_finalize(statement) }
            if let relativePath {
                try bind(relativePath, at: 1, in: statement, name: "保存阅读历史封面路径")
            } else {
                guard sqlite3_bind_null(statement, 1) == SQLITE_OK else {
                    throw currentError(name: "保存阅读历史封面路径")
                }
            }
            try bind(comicID, at: 2, in: statement, name: "保存阅读历史封面路径")
            try stepDone(statement, name: "保存阅读历史封面路径")
            guard sqlite3_changes(try handle()) > 0 else {
                throw ReadingHistoryDatabaseError.invalidData("找不到阅读历史漫画 \(comicID)")
            }
        }
    }

    private func createSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS reading_history (
                comic_id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                chapter_id TEXT NOT NULL,
                chapter_title TEXT NOT NULL,
                page_index INTEGER NOT NULL CHECK (page_index >= 0),
                cover_relative_path TEXT,
                first_viewed_at REAL NOT NULL,
                last_viewed_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS history_authors (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL UNIQUE
            );

            CREATE TABLE IF NOT EXISTS history_tags (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL UNIQUE
            );

            CREATE TABLE IF NOT EXISTS reading_history_authors (
                comic_id TEXT NOT NULL,
                author_id INTEGER NOT NULL,
                position INTEGER NOT NULL,
                PRIMARY KEY (comic_id, author_id),
                FOREIGN KEY (comic_id) REFERENCES reading_history(comic_id) ON DELETE CASCADE,
                FOREIGN KEY (author_id) REFERENCES history_authors(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS reading_history_tags (
                comic_id TEXT NOT NULL,
                tag_id INTEGER NOT NULL,
                position INTEGER NOT NULL,
                PRIMARY KEY (comic_id, tag_id),
                FOREIGN KEY (comic_id) REFERENCES reading_history(comic_id) ON DELETE CASCADE,
                FOREIGN KEY (tag_id) REFERENCES history_tags(id) ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS idx_reading_history_recent
                ON reading_history(last_viewed_at DESC, comic_id);
            CREATE INDEX IF NOT EXISTS idx_reading_history_authors_order
                ON reading_history_authors(comic_id, position);
            CREATE INDEX IF NOT EXISTS idx_reading_history_tags_order
                ON reading_history_tags(comic_id, position);
            """,
            name: "创建阅读历史索引"
        )
        try ensureCoverRelativePathColumn()
        try execute(
            """
            CREATE INDEX IF NOT EXISTS idx_reading_history_cover_relative_path
                ON reading_history(cover_relative_path)
                WHERE cover_relative_path IS NOT NULL
            """,
            name: "创建阅读历史封面引用索引"
        )
    }

    /// `CREATE TABLE IF NOT EXISTS` does not update installations created by
    /// earlier builds. Keep this independent of another store's user_version so
    /// opening either SQLite connection in any order remains safe and repeatable.
    private func ensureCoverRelativePathColumn() throws {
        var hasColumn = false
        let statement = try prepare(
            "PRAGMA table_info(reading_history)",
            name: "检查阅读历史封面路径"
        )
        defer { sqlite3_finalize(statement) }
        try consumeRows(statement, name: "检查阅读历史封面路径") { row in
            if text(row, 1) == "cover_relative_path" { hasColumn = true }
        }
        if !hasColumn {
            try execute(
                "ALTER TABLE reading_history ADD COLUMN cover_relative_path TEXT",
                name: "迁移阅读历史封面路径"
            )
        }
    }

    private func coverRelativePathsForTrim(maximumEntries: Int) throws -> [String] {
        let statement = try prepare(
            """
            SELECT cover_relative_path FROM reading_history
            WHERE comic_id IN (
                SELECT comic_id FROM reading_history
                ORDER BY last_viewed_at DESC, comic_id
                LIMIT -1 OFFSET ?
            )
              AND cover_relative_path IS NOT NULL
            """,
            name: "读取被淘汰阅读历史封面"
        )
        defer { sqlite3_finalize(statement) }
        try bind(maximumEntries, at: 1, in: statement, name: "读取被淘汰阅读历史封面")
        return try coverRelativePaths(from: statement, operation: "读取被淘汰阅读历史封面")
    }

    private func allCoverRelativePaths() throws -> [String] {
        let statement = try prepare(
            "SELECT cover_relative_path FROM reading_history WHERE cover_relative_path IS NOT NULL",
            name: "读取全部阅读历史封面"
        )
        defer { sqlite3_finalize(statement) }
        return try coverRelativePaths(from: statement, operation: "读取全部阅读历史封面")
    }

    private func coverRelativePaths(
        from statement: OpaquePointer,
        operation: String
    ) throws -> [String] {
        var paths: Set<String> = []
        try consumeRows(statement, name: operation) { row in
            if let path = safeCoverRelativePath(optionalText(row, 0)) {
                paths.insert(path)
            }
        }
        return paths.sorted()
    }

    private func safeCoverRelativePath(_ value: String?) -> String? {
        guard let value, JMComicCoverCacheStorage.isSafeRelativePath(value) else { return nil }
        return value
    }

    private func replaceNames(
        comicID: String,
        values: [String],
        dictionaryTable: String,
        junctionTable: String,
        foreignKey: String,
        operation: String
    ) throws {
        try execute("DELETE FROM \(junctionTable) WHERE comic_id = ?", name: operation) { statement in
            try self.bind(comicID, at: 1, in: statement, name: operation)
        }
        var seen: Set<String> = []
        for (position, value) in values.enumerated() where !value.isEmpty && seen.insert(value).inserted {
            try execute(
                "INSERT INTO \(dictionaryTable) (name) VALUES (?) ON CONFLICT(name) DO NOTHING",
                name: operation
            ) { statement in
                try self.bind(value, at: 1, in: statement, name: operation)
            }
            let lookup = try prepare("SELECT id FROM \(dictionaryTable) WHERE name = ?", name: operation)
            defer { sqlite3_finalize(lookup) }
            try bind(value, at: 1, in: lookup, name: operation)
            guard sqlite3_step(lookup) == SQLITE_ROW else { throw currentError(name: operation) }
            let nameID = Int(sqlite3_column_int64(lookup, 0))
            try execute(
                "INSERT INTO \(junctionTable) (comic_id, \(foreignKey), position) VALUES (?, ?, ?)",
                name: operation
            ) { statement in
                try self.bind(comicID, at: 1, in: statement, name: operation)
                try self.bind(nameID, at: 2, in: statement, name: operation)
                try self.bind(position, at: 3, in: statement, name: operation)
            }
        }
    }

    private func names(
        comicIDs: [String],
        dictionaryTable: String,
        junctionTable: String,
        foreignKey: String,
        operation: String
    ) throws -> [String: [String]] {
        guard !comicIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: comicIDs.count).joined(separator: ",")
        let statement = try prepare(
            """
            SELECT j.comic_id, d.name
            FROM \(junctionTable) j
            JOIN \(dictionaryTable) d ON d.id = j.\(foreignKey)
            WHERE j.comic_id IN (\(placeholders))
            ORDER BY j.comic_id, j.position
            """,
            name: operation
        )
        defer { sqlite3_finalize(statement) }
        for (offset, comicID) in comicIDs.enumerated() {
            try bind(comicID, at: Int32(offset + 1), in: statement, name: operation)
        }
        var result: [String: [String]] = [:]
        try consumeRows(statement, name: operation) { row in
            result[text(row, 0), default: []].append(text(row, 1))
        }
        return result
    }

    private func cleanupOrphanNames() throws {
        try execute(
            "DELETE FROM history_authors WHERE NOT EXISTS "
                + "(SELECT 1 FROM reading_history_authors WHERE author_id = history_authors.id)",
            name: "清理历史作者索引"
        )
        try execute(
            "DELETE FROM history_tags WHERE NOT EXISTS "
                + "(SELECT 1 FROM reading_history_tags WHERE tag_id = history_tags.id)",
            name: "清理历史标签索引"
        )
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func transaction<T>(begin: String = "BEGIN IMMEDIATE", _ body: () throws -> T) throws -> T {
        try execute(begin, name: "开始阅读历史事务")
        do {
            let value = try body()
            try execute("COMMIT", name: "提交阅读历史事务")
            return value
        } catch {
            try? execute("ROLLBACK", name: "回滚阅读历史事务")
            throw error
        }
    }

    private func handle() throws -> OpaquePointer {
        guard let database else {
            throw ReadingHistoryDatabaseError.invalidData("数据库连接已关闭")
        }
        return database
    }

    private func execute(
        _ sql: String,
        name: String,
        bindValues: ((OpaquePointer) throws -> Void)? = nil
    ) throws {
        if let bindValues {
            let statement = try prepare(sql, name: name)
            defer { sqlite3_finalize(statement) }
            try bindValues(statement)
            try stepDone(statement, name: name)
            return
        }
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(try handle(), sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let text: String
            if let message {
                text = String(cString: message)
            } else {
                text = String(cString: sqlite3_errmsg(try handle()))
            }
            sqlite3_free(message)
            throw ReadingHistoryDatabaseError.operation(name: name, code: result, message: text)
        }
    }

    private func prepare(_ sql: String, name: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(try handle(), sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw currentError(name: name, code: result) }
        return statement
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer, name: String) throws {
        let result = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, Self.sqliteTransient)
        }
        guard result == SQLITE_OK else { throw currentError(name: name, code: result) }
    }

    private func bind(_ value: Int, at index: Int32, in statement: OpaquePointer, name: String) throws {
        let result = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
        guard result == SQLITE_OK else { throw currentError(name: name, code: result) }
    }

    private func bind(_ value: Double, at index: Int32, in statement: OpaquePointer, name: String) throws {
        let result = sqlite3_bind_double(statement, index, value)
        guard result == SQLITE_OK else { throw currentError(name: name, code: result) }
    }

    private func stepDone(_ statement: OpaquePointer, name: String) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw currentError(name: name, code: result) }
    }

    private func consumeRows(
        _ statement: OpaquePointer,
        name: String,
        row: (OpaquePointer) throws -> Void
    ) throws {
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try row(statement)
            case SQLITE_DONE: return
            case let code: throw currentError(name: name, code: code)
            }
        }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column) else { return nil }
        let result = String(cString: value)
        return result.isEmpty ? nil : result
    }

    private func currentError(name: String, code: Int32? = nil) -> ReadingHistoryDatabaseError {
        let resolvedCode = code ?? database.map(sqlite3_errcode) ?? SQLITE_MISUSE
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "database closed"
        return .operation(name: name, code: resolvedCode, message: message)
    }
}

/// Serializes every history operation in submission order. Besides keeping
/// SQLite work off the main actor, this makes `clear()` a real barrier: a page
/// write that has already started finishes before the clear, while a debounced
/// write that has not started is cancelled and never reaches the queue.
private final class ReadingHistoryWorker: @unchecked Sendable {
    private let database: ReadingHistoryDatabase
    private let queue = DispatchQueue(label: "io.github.jmcomic.reading-history", qos: .utility)

    init(database: ReadingHistoryDatabase) {
        self.database = database
    }

    func record(comic: ComicSummary, chapter: Chapter, pageIndex: Int) async throws -> [String] {
        try await perform {
            try self.database.record(comic: comic, chapter: chapter, pageIndex: pageIndex)
        }
    }

    func page(offset: Int, limit: Int) async throws -> [ReadingHistoryEntry] {
        try await perform { try self.database.page(offset: offset, limit: limit) }
    }

    func clear() async throws -> [String] {
        try await perform { try self.database.clear() }
    }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

@MainActor
final class ReadingHistoryStore: ObservableObject {
    @Published private(set) var recent: [ReadingHistoryEntry] = []
    @Published private(set) var error: String?

    private struct PendingRecord {
        let token: UUID
        let task: Task<Void, Never>
    }

    private let worker: ReadingHistoryWorker?
    private let documentsRoot: URL
    private let coverReferenceDatabase: OfflineLibraryDatabase?
    private var pendingRecords: [String: PendingRecord] = [:]
    private var loadGeneration = UUID()

    init(
        databaseURL: URL = JMComicDatabase.databaseURL,
        documentsRoot: URL? = nil,
        coverReferenceDatabase: OfflineLibraryDatabase? = nil
    ) {
        let isDefaultDatabase = databaseURL.standardizedFileURL
            == JMComicDatabase.databaseURL.standardizedFileURL
        if let documentsRoot {
            self.documentsRoot = documentsRoot
        } else if isDefaultDatabase {
            self.documentsRoot = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]
        } else if databaseURL.deletingLastPathComponent().lastPathComponent
                    == JMComicStorageLayout.databaseDirectoryName {
            self.documentsRoot = databaseURL.deletingLastPathComponent().deletingLastPathComponent()
        } else {
            self.documentsRoot = databaseURL.deletingLastPathComponent()
        }
        self.coverReferenceDatabase = coverReferenceDatabase
            ?? (isDefaultDatabase
                ? JMComicDatabase.shared
                : try? OfflineLibraryDatabase(databaseURL: databaseURL))
        do {
            worker = ReadingHistoryWorker(
                database: try ReadingHistoryDatabase(databaseURL: databaseURL)
            )
        } catch {
            worker = nil
            self.error = error.localizedDescription
        }
    }

    func record(comic: ComicSummary, chapter: Chapter, pageIndex: Int) {
        guard let worker else { return }
        pendingRecords[comic.id]?.task.cancel()
        let token = UUID()
        let task = Task { [weak self] in
            defer { self?.finishPendingRecord(comicID: comic.id, token: token) }
            do {
                try await Task.sleep(for: .milliseconds(220))
                try Task.checkCancellation()
                let evictedCoverPaths = try await worker.record(
                    comic: comic,
                    chapter: chapter,
                    pageIndex: pageIndex
                )
                let referenceDatabase = self?.coverReferenceDatabase
                let coverRoot = self?.documentsRoot
                if let coverRoot {
                    await Task.detached(priority: .utility) {
                        Self.removeUnreferencedCoverFiles(
                            evictedCoverPaths,
                            database: referenceDatabase,
                            documentsRoot: coverRoot
                        )
                    }.value
                }
                guard !Task.isCancelled else { return }
                await self?.refreshRecent()
            } catch is CancellationError {
                // Rapid page changes are deliberately coalesced into the latest row.
            } catch {
                self?.error = error.localizedDescription
            }
        }
        pendingRecords[comic.id] = PendingRecord(token: token, task: task)
    }

    func refreshRecent(limit: Int = 8) async {
        guard let worker else { return }
        let generation = UUID()
        loadGeneration = generation
        do {
            let loaded = try await worker.page(offset: 0, limit: limit)
            guard loadGeneration == generation else { return }
            recent = loaded
            error = nil
        } catch {
            guard loadGeneration == generation else { return }
            self.error = error.localizedDescription
        }
    }

    func page(offset: Int, limit: Int) async throws -> [ReadingHistoryEntry] {
        guard let worker else {
            throw ReadingHistoryDatabaseError.invalidData(error ?? "阅读历史数据库未初始化")
        }
        return try await worker.page(offset: offset, limit: limit)
    }

    func clear() async throws {
        guard let worker else {
            throw ReadingHistoryDatabaseError.invalidData(error ?? "阅读历史数据库未初始化")
        }
        let recordsToDrain = pendingRecords.values.map(\.task)
        pendingRecords.removeAll()
        recordsToDrain.forEach { $0.cancel() }
        // Cancellation can race with the instant the debounced task submits
        // its SQLite write. Drain them before queuing clear so no old page can
        // reappear after the user sees an empty history.
        for task in recordsToDrain { await task.value }
        loadGeneration = UUID()
        do {
            let coverRelativePaths = try await worker.clear()
            let referenceDatabase = coverReferenceDatabase
            let coverRoot = documentsRoot
            await Task.detached(priority: .utility) {
                Self.removeUnreferencedCoverFiles(
                    coverRelativePaths,
                    database: referenceDatabase,
                    documentsRoot: coverRoot
                )
            }.value
            recent = []
            error = nil
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }

    private func finishPendingRecord(comicID: String, token: UUID) {
        guard pendingRecords[comicID]?.token == token else { return }
        pendingRecords[comicID] = nil
    }

    /// Delete a physical cover only after every SQLite-backed owner has released
    /// the shared relative path. Any lookup error conservatively keeps the file.
    nonisolated static func removeUnreferencedCoverFiles(
        _ relativePaths: [String],
        database: OfflineLibraryDatabase?,
        documentsRoot: URL,
        fileManager: FileManager = .default
    ) {
        guard let database else { return }
        for relativePath in Set(relativePaths)
        where JMComicCoverCacheStorage.isSafeRelativePath(relativePath) {
            guard (try? database.isCoverRelativePathReferenced(relativePath)) == false,
                  let url = JMComicCoverCacheStorage.fileURL(
                    relativePath: relativePath,
                    documentsRoot: documentsRoot
                  ),
                  fileManager.fileExists(atPath: url.path) else { continue }
            try? fileManager.removeItem(at: url)
        }
    }
}
