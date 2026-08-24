import Foundation
import SQLite3

struct OfflinePageRecord: Hashable {
    let chapterID: String
    let pageIndex: Int
    let globalOrdinal: Int
    let relativePath: String
    let completed: Bool
}

struct CachedFavoritePage {
    let total: Int
    let comics: [ComicSummary]
    let coverRelativePaths: [String: String]
}

struct SearchHistoryEntry: Identifiable, Hashable, Sendable {
    let queryKey: String
    let query: String
    let lastSearchedAt: Date

    var id: String { queryKey }
}

enum SearchHistoryNormalization {
    static func value(from rawValue: String) -> (key: String, display: String)? {
        let display = rawValue
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !display.isEmpty else { return nil }
        let locale = Locale(identifier: "en_US_POSIX")
        let key = display
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: locale)
            .lowercased(with: locale)
        return (key, display)
    }
}

struct OfflineFavoriteFolderAssignment: Hashable {
    let folderID: String
    let folderName: String
    let sort: Int
}

/// Upstream `/favorite` ordering values. Keep the wire values here so SQLite
/// namespaces and requests cannot accidentally mix the two independent lists.
enum FavoriteComicSortOrder: String, CaseIterable {
    /// `mr`: the user's original favorite/addition order.
    case added = "mr"
    /// `mp`: JM's comic upload/latest-chapter update order.
    case updated = "mp"
}

enum JMComicDatabase {
    static let databaseURL: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            return try JMComicStorageLayout.prepareDatabaseDirectory(
                documentsRoot: documents,
                fileManager: .default
            )
        } catch {
            // Never replace a valid old index with an empty new database just
            // because a one-time move hit low storage or a Files-provider error.
            let legacy = documents.appendingPathComponent("JMComic.db")
            if FileManager.default.fileExists(atPath: legacy.path) { return legacy }
            return documents.appendingPathComponent("database/JMComic.db")
        }
    }()
    static let shared = try? OfflineLibraryDatabase(databaseURL: databaseURL)
}

/// User-visible Files layout. `Documents` is presented by iOS as
/// "On My iPhone/iPad/JMComic", so these URLs become `JMComic/download`,
/// `JMComic/cache`, and `JMComic/database` without introducing another
/// redundant JMComic level.
enum JMComicStorageLayout {
    static let downloadDirectoryName = "download"
    static let cacheDirectoryName = "cache"
    static let databaseDirectoryName = "database"
    static let databaseFileName = "JMComic.db"

    static func downloadRoot(documentsRoot: URL) -> URL {
        documentsRoot.appendingPathComponent(downloadDirectoryName, isDirectory: true)
    }

    static func cacheRoot(documentsRoot: URL) -> URL {
        documentsRoot.appendingPathComponent(cacheDirectoryName, isDirectory: true)
    }

    static func databaseURL(documentsRoot: URL) -> URL {
        documentsRoot
            .appendingPathComponent(databaseDirectoryName, isDirectory: true)
            .appendingPathComponent(databaseFileName)
    }

    /// Migrates the SQLite database and its WAL sidecars before any connection
    /// opens the destination. The base file is published last, making a crash
    /// during staging safe to retry on the next launch.
    @discardableResult
    static func prepareDatabaseDirectory(
        documentsRoot: URL,
        fileManager: FileManager
    ) throws -> URL {
        let directory = documentsRoot.appendingPathComponent(databaseDirectoryName, isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        let destination = directory.appendingPathComponent(databaseFileName)
        let legacy = documentsRoot.appendingPathComponent(databaseFileName)
        guard !fileManager.fileExists(atPath: destination.path),
              fileManager.fileExists(atPath: legacy.path) else { return destination }

        let staging = directory.appendingPathComponent(".database-migration", isDirectory: true)
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let suffixes = ["-wal", "-shm", ""] // base file must be installed last
        for suffix in suffixes {
            let source = URL(fileURLWithPath: legacy.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let staged = staging.appendingPathComponent(databaseFileName + suffix)
            try fileManager.copyItem(at: source, to: staged)
            let sourceSize = try fileManager.attributesOfItem(atPath: source.path)[.size] as? NSNumber
            let stagedSize = try fileManager.attributesOfItem(atPath: staged.path)[.size] as? NSNumber
            guard sourceSize == stagedSize else {
                throw OfflineLibraryDatabaseError.invalidData("数据库迁移校验失败：\(source.lastPathComponent)")
            }
        }

        for suffix in suffixes {
            let staged = staging.appendingPathComponent(databaseFileName + suffix)
            guard fileManager.fileExists(atPath: staged.path) else { continue }
            let target = URL(fileURLWithPath: destination.path + suffix)
            if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
            try fileManager.moveItem(at: staged, to: target)
        }

        // Remove the old files only after the destination base file exists.
        if fileManager.fileExists(atPath: destination.path) {
            for suffix in ["", "-wal", "-shm"] {
                try? fileManager.removeItem(at: URL(fileURLWithPath: legacy.path + suffix))
            }
        }
        return destination
    }
}

/// Stable, container-independent paths for downloaded-comic covers. The
/// short digest prevents two unusual IDs that sanitize to the same filename
/// from sharing a cache entry.
enum JMComicCoverCacheStorage {
    static func relativePath(comicID: String) -> String {
        let safeID = DownloadStorageNaming.safeComponent(comicID, maxUTF8Bytes: 96)
        let digest = String(JMCrypto.md5(comicID).prefix(12))
        return "\(JMComicStorageLayout.cacheDirectoryName)/JM\(safeID)-\(digest).jpg"
    }

    static func isSafeRelativePath(_ value: String) -> Bool {
        let components = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return components.count == 2
            && components[0] == JMComicStorageLayout.cacheDirectoryName
            && DownloadStorageNaming.isSafeComponent(components[1])
    }

    static func fileURL(relativePath: String, documentsRoot: URL) -> URL? {
        guard isSafeRelativePath(relativePath) else { return nil }
        return documentsRoot.appendingPathComponent(relativePath, isDirectory: false)
    }
}

enum OfflineLibraryDatabaseError: LocalizedError {
    case open(path: String, code: Int32, message: String)
    case operation(name: String, code: Int32, message: String)
    case invalidData(String)

    var errorDescription: String? {
        switch self {
        case let .open(path, code, message):
            return "无法打开离线索引数据库 \(path) (SQLite \(code)): \(message)"
        case let .operation(name, code, message):
            return "离线索引操作“\(name)”失败 (SQLite \(code)): \(message)"
        case let .invalidData(message):
            return "离线索引数据无效：\(message)"
        }
    }
}

/// SQLite-backed index for the user-visible JMComic download directory.
///
/// The database is intentionally created at the URL supplied by the caller so
/// it can live in the visible Documents/database folder. All methods
/// are synchronous and serialized; callers may invoke them from any thread.
final class OfflineLibraryDatabase {
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let lock = NSLock()
    private var database: OpaquePointer?
    let databaseURL: URL

    init(databaseURL: URL) throws {
        self.databaseURL = databaseURL

        let parent = databaseURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
        } catch {
            throw OfflineLibraryDatabaseError.invalidData("无法创建索引目录 \(parent.path): \(error.localizedDescription)")
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = databaseURL.path.withCString { path in
            sqlite3_open_v2(path, &handle, flags, nil)
        }
        guard result == SQLITE_OK, let handle else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close_v2(handle) }
            throw OfflineLibraryDatabaseError.open(path: databaseURL.path, code: result, message: message)
        }
        database = handle

        do {
            try execute("PRAGMA foreign_keys = ON", name: "启用外键")
            try execute("PRAGMA journal_mode = WAL", name: "启用 WAL")
            try execute("PRAGMA synchronous = NORMAL", name: "设置同步等级")
            try execute("PRAGMA busy_timeout = 5000", name: "设置忙等待")
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

    func loadLibrary() throws -> [OfflineComic] {
        try synchronized {
            try transaction(begin: "BEGIN DEFERRED") {
                struct ComicRow {
                    let id: String
                    let name: String
                    let directoryName: String
                    let coverRelativePath: String?
                    let addedAt: Date
                    let updatedAt: Date
                }
                struct ChapterRow {
                    let id: String
                    let comicID: String
                    let title: String
                    let sort: Int
                    let expectedPageCount: Int
                }

                var comics: [ComicRow] = []
                try query(
                    "SELECT id, name, storage_directory_name, cover_relative_path, added_at, updated_at FROM comics ORDER BY added_at DESC, id",
                    name: "读取离线漫画"
                ) { statement in
                    comics.append(ComicRow(
                        id: text(statement, 0),
                        name: text(statement, 1),
                        directoryName: text(statement, 2),
                        coverRelativePath: optionalText(statement, 3),
                        addedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                        updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
                    ))
                }

                var authors: [String: [String]] = [:]
                try query(
                    """
                    SELECT ca.comic_id, a.name
                    FROM comic_authors ca
                    JOIN authors a ON a.id = ca.author_id
                    ORDER BY ca.comic_id, ca.position, a.id
                    """,
                    name: "读取作者"
                ) { statement in
                    authors[text(statement, 0), default: []].append(text(statement, 1))
                }

                var tags: [String: [String]] = [:]
                try query(
                    """
                    SELECT ct.comic_id, t.name
                    FROM comic_tags ct
                    JOIN tags t ON t.id = ct.tag_id
                    ORDER BY ct.comic_id, ct.position, t.id
                    """,
                    name: "读取标签"
                ) { statement in
                    tags[text(statement, 0), default: []].append(text(statement, 1))
                }

                var chapterRows: [String: [ChapterRow]] = [:]
                try query(
                    """
                    SELECT id, comic_id, title, sort, expected_page_count
                    FROM chapters
                    ORDER BY comic_id, sort, id
                    """,
                    name: "读取章节"
                ) { statement in
                    let row = ChapterRow(
                        id: text(statement, 0),
                        comicID: text(statement, 1),
                        title: text(statement, 2),
                        sort: Int(sqlite3_column_int64(statement, 3)),
                        expectedPageCount: Int(sqlite3_column_int64(statement, 4))
                    )
                    chapterRows[row.comicID, default: []].append(row)
                }

                // Reserved/in-flight rows deliberately do not become readable pages.
                var paths: [String: [String]] = [:]
                try query(
                    """
                    SELECT chapter_id, relative_path
                    FROM pages
                    WHERE completed = 1
                    ORDER BY chapter_id, page_index
                    """,
                    name: "读取已完成页"
                ) { statement in
                    paths[text(statement, 0), default: []].append(text(statement, 1))
                }

                return comics.map { row in
                    let summary = ComicSummary(
                        id: row.id,
                        name: row.name,
                        authors: authors[row.id] ?? [],
                        tags: tags[row.id] ?? []
                    )
                    let offlineChapters = (chapterRows[row.id] ?? []).map { chapter in
                        OfflineChapter(
                            id: chapter.id,
                            title: chapter.title,
                            sort: chapter.sort,
                            relativePagePaths: paths[chapter.id] ?? [],
                            expectedPageCount: chapter.expectedPageCount
                        )
                    }
                    return OfflineComic(
                        comic: summary,
                        storageDirectoryName: row.directoryName,
                        coverRelativePath: row.coverRelativePath,
                        chapters: offlineChapters,
                        addedAt: row.addedAt,
                        updatedAt: row.updatedAt
                    )
                }
            }
        }
    }

    func upsertComic(_ comic: ComicSummary, storageDirectoryName: String) throws {
        try synchronized {
            try transaction {
                try upsertComicUnlocked(
                    comic,
                    storageDirectoryName: storageDirectoryName,
                    updatedAt: .now
                )
            }
        }
    }

    func setComicCoverRelativePath(comicID: String, relativePath: String?) throws {
        guard !comicID.isEmpty else {
            throw OfflineLibraryDatabaseError.invalidData("漫画 ID 不能为空")
        }
        if let relativePath, !JMComicCoverCacheStorage.isSafeRelativePath(relativePath) {
            throw OfflineLibraryDatabaseError.invalidData("封面缓存路径不安全: \(relativePath)")
        }
        try synchronized {
            try transaction {
                let statement = try prepare(
                    relativePath == nil
                        ? "UPDATE comics SET cover_relative_path = NULL WHERE id = ?"
                        : "UPDATE comics SET cover_relative_path = ? WHERE id = ?",
                    name: "保存离线封面路径"
                )
                defer { sqlite3_finalize(statement) }
                if let relativePath {
                    try bind(relativePath, to: 1, in: statement, name: "保存离线封面路径")
                    try bind(comicID, to: 2, in: statement, name: "保存离线封面路径")
                } else {
                    try bind(comicID, to: 1, in: statement, name: "保存离线封面路径")
                }
                try stepDone(statement, name: "保存离线封面路径")
                guard sqlite3_changes(try handle()) > 0 else {
                    throw OfflineLibraryDatabaseError.invalidData("找不到离线漫画 \(comicID)")
                }
            }
        }
    }

    func comicCoverRelativePath(comicID: String) throws -> String? {
        guard !comicID.isEmpty else {
            throw OfflineLibraryDatabaseError.invalidData("漫画 ID 不能为空")
        }
        return try synchronized {
            let statement = try prepare(
                "SELECT cover_relative_path FROM comics WHERE id = ?",
                name: "读取离线封面路径"
            )
            defer { sqlite3_finalize(statement) }
            try bind(comicID, to: 1, in: statement, name: "读取离线封面路径")
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                return optionalText(statement, 0)
            case SQLITE_DONE:
                return nil
            default:
                throw currentError(name: "读取离线封面路径")
            }
        }
    }

    func upsertChapter(comicID: String, chapter: Chapter, expectedPageCount: Int) throws {
        try synchronized {
            try transaction {
                try upsertChapterUnlocked(
                    comicID: comicID,
                    chapter: chapter,
                    expectedPageCount: expectedPageCount
                )
                try touchComic(forChapterID: chapter.id)
            }
        }
    }

    /// Reserves a stable filename/ordinal before a background URLSession task starts.
    func reservePage(
        chapterID: String,
        pageIndex: Int,
        globalOrdinal: Int,
        relativePath: String
    ) throws {
        try validatePageValues(pageIndex: pageIndex, globalOrdinal: globalOrdinal, relativePath: relativePath)
        try synchronized {
            try transaction {
                try writePage(
                    chapterID: chapterID,
                    pageIndex: pageIndex,
                    globalOrdinal: globalOrdinal,
                    relativePath: relativePath,
                    completed: false,
                    preserveMatchingCompletion: true
                )
                try touchComic(forChapterID: chapterID)
            }
        }
    }

    func markPageCompleted(chapterID: String, pageIndex: Int) throws {
        guard pageIndex >= 0 else {
            throw OfflineLibraryDatabaseError.invalidData("页索引不能为负数: \(pageIndex)")
        }
        try synchronized {
            try transaction {
                let statement = try prepare(
                    "UPDATE pages SET completed = 1 WHERE chapter_id = ? AND page_index = ?",
                    name: "标记页完成"
                )
                defer { sqlite3_finalize(statement) }
                try bind(chapterID, to: 1, in: statement, name: "标记页完成")
                try bind(pageIndex, to: 2, in: statement, name: "标记页完成")
                try stepDone(statement, name: "标记页完成")
                guard sqlite3_changes(try handle()) > 0 else {
                    throw OfflineLibraryDatabaseError.invalidData(
                        "找不到待完成的页：chapter=\(chapterID), page=\(pageIndex)"
                    )
                }
                try touchComic(forChapterID: chapterID)
            }
        }
    }

    /// Inserts a completed page, or atomically turns an existing reservation into one.
    func upsertPage(
        chapterID: String,
        pageIndex: Int,
        globalOrdinal: Int,
        relativePath: String
    ) throws {
        try validatePageValues(pageIndex: pageIndex, globalOrdinal: globalOrdinal, relativePath: relativePath)
        try synchronized {
            try transaction {
                try writePage(
                    chapterID: chapterID,
                    pageIndex: pageIndex,
                    globalOrdinal: globalOrdinal,
                    relativePath: relativePath,
                    completed: true,
                    preserveMatchingCompletion: false
                )
                try touchComic(forChapterID: chapterID)
            }
        }
    }

    func pageRecords(comicID: String, chapterID: String) throws -> [OfflinePageRecord] {
        try synchronized {
            var records: [OfflinePageRecord] = []
            let statement = try prepare(
                """
                SELECT p.chapter_id, p.page_index, p.global_ordinal, p.relative_path, p.completed
                FROM pages p
                JOIN chapters c ON c.id = p.chapter_id
                WHERE c.comic_id = ? AND c.id = ?
                ORDER BY p.page_index
                """,
                name: "读取章节页索引"
            )
            defer { sqlite3_finalize(statement) }
            try bind(comicID, to: 1, in: statement, name: "读取章节页索引")
            try bind(chapterID, to: 2, in: statement, name: "读取章节页索引")
            try consumeRows(statement, name: "读取章节页索引") { row in
                records.append(pageRecord(from: row))
            }
            return records
        }
    }

    func allPageRecords(comicID: String) throws -> [OfflinePageRecord] {
        try synchronized {
            var records: [OfflinePageRecord] = []
            let statement = try prepare(
                """
                SELECT p.chapter_id, p.page_index, p.global_ordinal, p.relative_path, p.completed
                FROM pages p
                JOIN chapters c ON c.id = p.chapter_id
                WHERE c.comic_id = ?
                ORDER BY p.global_ordinal, p.chapter_id, p.page_index
                """,
                name: "读取漫画全部页索引"
            )
            defer { sqlite3_finalize(statement) }
            try bind(comicID, to: 1, in: statement, name: "读取漫画全部页索引")
            try consumeRows(statement, name: "读取漫画全部页索引") { row in
                records.append(pageRecord(from: row))
            }
            return records
        }
    }

    /// Includes incomplete reservations so multiple batches never reuse a filename.
    func nextGlobalOrdinal(comicID: String) throws -> Int {
        try synchronized {
            let statement = try prepare(
                """
                SELECT COALESCE(MAX(p.global_ordinal), 0) + 1
                FROM pages p
                JOIN chapters c ON c.id = p.chapter_id
                WHERE c.comic_id = ?
                """,
                name: "计算下一图片编号"
            )
            defer { sqlite3_finalize(statement) }
            try bind(comicID, to: 1, in: statement, name: "计算下一图片编号")
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw currentError(name: "计算下一图片编号")
            }
            return max(1, Int(sqlite3_column_int64(statement, 0)))
        }
    }

    func deletePage(chapterID: String, pageIndex: Int) throws {
        try synchronized {
            try transaction {
                let statement = try prepare(
                    "DELETE FROM pages WHERE chapter_id = ? AND page_index = ?",
                    name: "删除页索引"
                )
                defer { sqlite3_finalize(statement) }
                try bind(chapterID, to: 1, in: statement, name: "删除页索引")
                try bind(pageIndex, to: 2, in: statement, name: "删除页索引")
                try stepDone(statement, name: "删除页索引")
                try touchComic(forChapterID: chapterID)
            }
        }
    }

    func deleteChapterPages(chapterID: String) throws {
        try synchronized {
            try transaction {
                let statement = try prepare(
                    "DELETE FROM pages WHERE chapter_id = ?",
                    name: "删除章节页索引"
                )
                defer { sqlite3_finalize(statement) }
                try bind(chapterID, to: 1, in: statement, name: "删除章节页索引")
                try stepDone(statement, name: "删除章节页索引")
                try touchComic(forChapterID: chapterID)
            }
        }
    }

    func deleteComic(comicID: String) throws {
        try synchronized {
            try transaction {
                let statement = try prepare("DELETE FROM comics WHERE id = ?", name: "删除离线漫画")
                defer { sqlite3_finalize(statement) }
                try bind(comicID, to: 1, in: statement, name: "删除离线漫画")
                try stepDone(statement, name: "删除离线漫画")
                // Junction rows cascade. Remove dictionary values no longer in use.
                try execute(
                    "DELETE FROM authors WHERE NOT EXISTS (SELECT 1 FROM comic_authors WHERE author_id = authors.id)",
                    name: "清理作者索引"
                )
                try execute(
                    "DELETE FROM tags WHERE NOT EXISTS (SELECT 1 FROM comic_tags WHERE tag_id = tags.id)",
                    name: "清理标签索引"
                )
            }
        }
    }

    /// One-time import helper for a former JSON index. It does not read JSON itself.
    func importLegacy(
        _ library: [OfflineComic],
        directoryName: (ComicSummary) -> String
    ) throws {
        try synchronized {
            try transaction {
                for comic in library {
                    let storedDirectory = comic.storageDirectoryName.isEmpty
                        ? directoryName(comic.comic)
                        : comic.storageDirectoryName
                    try upsertComicUnlocked(
                        comic.comic,
                        storageDirectoryName: storedDirectory,
                        updatedAt: comic.updatedAt
                    )
                    var ordinal = try nextGlobalOrdinalUnlocked(comicID: comic.id)
                    for (chapterOffset, chapter) in comic.chapters.enumerated() {
                        let sort = chapter.sort == 0 ? chapterOffset + 1 : chapter.sort
                        try upsertChapterUnlocked(
                            comicID: comic.id,
                            chapter: Chapter(id: chapter.id, title: chapter.title, sort: sort),
                            expectedPageCount: chapter.expectedPageCount
                        )
                        for (pageIndex, path) in chapter.relativePagePaths.enumerated() {
                            try writePage(
                                chapterID: chapter.id,
                                pageIndex: pageIndex,
                                globalOrdinal: ordinal,
                                relativePath: path,
                                completed: true,
                                preserveMatchingCompletion: false
                            )
                            ordinal += 1
                        }
                    }
                }
            }
        }
    }

    // MARK: - Favorite cache

    /// Replaces the account's folder metadata without marking folder contents as synced.
    /// Existing content-sync timestamps are deliberately preserved.
    func replaceFavoriteFolders(
        accountID: String,
        folders: [FavoriteFolder],
        at _: Date = .now
    ) throws {
        try validateAccountID(accountID)
        guard folders.contains(where: { $0.id == "0" }) else {
            throw OfflineLibraryDatabaseError.invalidData("收藏夹列表缺少“全部收藏”(folder 0)")
        }
        try synchronized {
            try transaction {
                try replaceFavoriteFoldersUnlocked(accountID: accountID, folders: folders)
            }
        }
    }

    func cachedFavoriteFolders(accountID: String) throws -> [FavoriteFolder] {
        try validateAccountID(accountID)
        return try synchronized {
            var folders: [FavoriteFolder] = []
            let statement = try prepare(
                """
                SELECT folder_id, name, total
                FROM favorite_folders
                WHERE account_id = ?
                ORDER BY sort, folder_id
                """,
                name: "读取收藏夹缓存"
            )
            defer { sqlite3_finalize(statement) }
            try bind(accountID, to: 1, in: statement, name: "读取收藏夹缓存")
            try consumeRows(statement, name: "读取收藏夹缓存") { row in
                folders.append(FavoriteFolder(
                    id: text(row, 0),
                    name: text(row, 1),
                    count: Int(sqlite3_column_int64(row, 2))
                ))
            }
            return folders
        }
    }

    /// Maps offline comics to the current account's locally cached favorite
    /// folders. A custom folder always wins over the aggregate folder `0`;
    /// multiple custom memberships use the folder's stable server order.
    func favoriteFolderAssignments(
        accountID: String,
        comicIDs: [String]
    ) throws -> [String: OfflineFavoriteFolderAssignment] {
        try validateAccountID(accountID)
        var seen: Set<String> = []
        let uniqueIDs = comicIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !uniqueIDs.isEmpty else { return [:] }

        return try synchronized {
            var assignments: [String: OfflineFavoriteFolderAssignment] = [:]
            // Keep well below SQLite's traditional 999-variable limit. The
            // account ID consumes one additional binding in every query.
            for chunkStart in stride(from: 0, to: uniqueIDs.count, by: 400) {
                let chunk = Array(uniqueIDs[chunkStart..<min(chunkStart + 400, uniqueIDs.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let statement = try prepare(
                    """
                    SELECT m.comic_id, f.folder_id, f.name, f.sort
                    FROM favorite_memberships m
                    JOIN favorite_folders f
                      ON f.account_id = m.account_id AND f.folder_id = m.folder_id
                    WHERE m.account_id = ? AND m.comic_id IN (\(placeholders))
                    GROUP BY m.comic_id, f.folder_id, f.name, f.sort
                    ORDER BY m.comic_id,
                             CASE WHEN f.folder_id = '0' THEN 1 ELSE 0 END,
                             f.sort,
                             f.folder_id
                    """,
                    name: "读取离线漫画收藏夹归类"
                )
                defer { sqlite3_finalize(statement) }
                try bind(accountID, to: 1, in: statement, name: "读取离线漫画收藏夹归类")
                for (offset, comicID) in chunk.enumerated() {
                    try bind(
                        comicID,
                        to: Int32(offset + 2),
                        in: statement,
                        name: "读取离线漫画收藏夹归类"
                    )
                }
                try consumeRows(statement, name: "读取离线漫画收藏夹归类") { row in
                    let comicID = text(row, 0)
                    guard assignments[comicID] == nil else { return }
                    let folderID = text(row, 1)
                    let rawName = text(row, 2).trimmingCharacters(in: .whitespacesAndNewlines)
                    assignments[comicID] = OfflineFavoriteFolderAssignment(
                        folderID: folderID,
                        folderName: rawName.isEmpty
                            ? (folderID == "0" ? "全部收藏" : folderID)
                            : rawName,
                        sort: Int(sqlite3_column_int64(row, 3))
                    )
                }
            }
            return assignments
        }
    }

    /// Returns only the requested comic IDs that already belong to this
    /// account/folder. The query is chunked so callers may safely pass a large
    /// candidate set without exceeding SQLite's bound-variable limit.
    func existingFavoriteComicIDs(
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder = .added,
        comicIDs: [String]
    ) throws -> Set<String> {
        try validateAccountID(accountID)
        guard !folderID.isEmpty else {
            throw OfflineLibraryDatabaseError.invalidData("收藏夹 ID 不能为空")
        }

        var seen: Set<String> = []
        var uniqueIDs: [String] = []
        uniqueIDs.reserveCapacity(comicIDs.count)
        for comicID in comicIDs {
            guard !comicID.isEmpty else {
                throw OfflineLibraryDatabaseError.invalidData("收藏漫画 ID 不能为空")
            }
            if seen.insert(comicID).inserted { uniqueIDs.append(comicID) }
        }
        guard !uniqueIDs.isEmpty else { return [] }

        return try synchronized {
            try existingFavoriteComicIDsUnlocked(
                accountID: accountID,
                folderID: folderID,
                sortOrder: sortOrder,
                comicIDs: uniqueIDs
            )
        }
    }

    /// Atomically prepends comics that are not already members of this folder.
    ///
    /// The membership check is repeated inside an IMMEDIATE transaction, so a
    /// caller may perform a preliminary `existingFavoriteComicIDs` check without
    /// introducing a time-of-check/time-of-use duplicate. Existing positions are
    /// shifted once, new rows retain their input order, and the folder total is
    /// set to the actual membership count. The return value is the number of new
    /// memberships inserted.
    @discardableResult
    func prependFavoriteComics(
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder = .added,
        comics: [ComicSummary],
        at: Date = .now
    ) throws -> Int {
        try validateAccountID(accountID)
        guard !folderID.isEmpty else {
            throw OfflineLibraryDatabaseError.invalidData("收藏夹 ID 不能为空")
        }

        var seen: Set<String> = []
        var candidates: [ComicSummary] = []
        candidates.reserveCapacity(comics.count)
        for comic in comics {
            guard !comic.id.isEmpty else {
                throw OfflineLibraryDatabaseError.invalidData("收藏漫画 ID 不能为空")
            }
            if seen.insert(comic.id).inserted { candidates.append(comic) }
        }

        return try synchronized {
            try transaction {
                try ensureFavoriteFolder(accountID: accountID, folderID: folderID, total: 0)

                let existingIDs = try existingFavoriteComicIDsUnlocked(
                    accountID: accountID,
                    folderID: folderID,
                    sortOrder: sortOrder,
                    comicIDs: candidates.map(\.id)
                )
                let newComics = candidates.filter { !existingIDs.contains($0.id) }

                if !newComics.isEmpty {
                    let shift = try prepare(
                        """
                        UPDATE favorite_memberships
                        SET position = position + ?
                        WHERE account_id = ? AND folder_id = ? AND order_mode = ?
                        """,
                        name: "后移原有收藏顺序"
                    )
                    defer { sqlite3_finalize(shift) }
                    try bind(newComics.count, to: 1, in: shift, name: "后移原有收藏顺序")
                    try bind(accountID, to: 2, in: shift, name: "后移原有收藏顺序")
                    try bind(folderID, to: 3, in: shift, name: "后移原有收藏顺序")
                    try bind(sortOrder.rawValue, to: 4, in: shift, name: "后移原有收藏顺序")
                    try stepDone(shift, name: "后移原有收藏顺序")

                    let membership = try prepare(
                        """
                        INSERT INTO favorite_memberships
                            (account_id, folder_id, order_mode, comic_id, position, sync_token)
                        VALUES (?, ?, ?, ?, ?, 'incremental')
                        """,
                        name: "追加增量收藏索引"
                    )
                    defer { sqlite3_finalize(membership) }

                    for (position, comic) in newComics.enumerated() {
                        try upsertFavoriteComic(accountID: accountID, comic: comic, updatedAt: at)
                        sqlite3_reset(membership)
                        sqlite3_clear_bindings(membership)
                        try bind(accountID, to: 1, in: membership, name: "追加增量收藏索引")
                        try bind(folderID, to: 2, in: membership, name: "追加增量收藏索引")
                        try bind(sortOrder.rawValue, to: 3, in: membership, name: "追加增量收藏索引")
                        try bind(comic.id, to: 4, in: membership, name: "追加增量收藏索引")
                        try bind(position, to: 5, in: membership, name: "追加增量收藏索引")
                        try stepDone(membership, name: "追加增量收藏索引")
                    }
                }

                let actualTotal = try favoriteMembershipCountUnlocked(
                    accountID: accountID,
                    folderID: folderID,
                    sortOrder: sortOrder
                )
                try updateFavoriteFolderTotal(
                    accountID: accountID,
                    folderID: folderID,
                    total: actualTotal
                )
                return newComics.count
            }
        }
    }

    /// Replaces the server-defined leading page while preserving the cached
    /// tail for this one order mode. This is used by `mp` refreshes: an existing
    /// comic can become recently updated, so an ID-existence check is not a
    /// valid stopping rule. Rows in `mr` and other folders are untouched.
    func replaceFavoriteLeadingPage(
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder,
        comics: [ComicSummary],
        remoteTotal: Int,
        at: Date = .now
    ) throws {
        try validateAccountID(accountID)
        guard !folderID.isEmpty else {
            throw OfflineLibraryDatabaseError.invalidData("收藏夹 ID 不能为空")
        }
        guard remoteTotal >= 0 else {
            throw OfflineLibraryDatabaseError.invalidData("收藏总数不能为负数")
        }

        var seen: Set<String> = []
        let leading = try comics.filter { comic in
            guard !comic.id.isEmpty else {
                throw OfflineLibraryDatabaseError.invalidData("收藏漫画 ID 不能为空")
            }
            return seen.insert(comic.id).inserted
        }
        guard leading.count <= remoteTotal else {
            throw OfflineLibraryDatabaseError.invalidData("收藏首页数量超过服务器总数")
        }

        try synchronized {
            try transaction {
                try ensureFavoriteFolder(
                    accountID: accountID,
                    folderID: folderID,
                    total: remoteTotal
                )
                try updateFavoriteFolderTotal(
                    accountID: accountID,
                    folderID: folderID,
                    total: remoteTotal
                )

                for comic in leading {
                    try upsertFavoriteComic(accountID: accountID, comic: comic, updatedAt: at)
                }

                // Read the old sequence before rebuilding it. A blanket
                // position shift creates holes whenever the new leading page
                // already contains rows from the old leading page.
                var oldSequence: [(comicID: String, syncToken: String)] = []
                let oldRows = try prepare(
                    """
                    SELECT comic_id, sync_token
                    FROM favorite_memberships
                    WHERE account_id = ? AND folder_id = ? AND order_mode = ?
                    ORDER BY position, comic_id
                    """,
                    name: "读取最近更新旧顺序"
                )
                defer { sqlite3_finalize(oldRows) }
                try bind(accountID, to: 1, in: oldRows, name: "读取最近更新旧顺序")
                try bind(folderID, to: 2, in: oldRows, name: "读取最近更新旧顺序")
                try bind(sortOrder.rawValue, to: 3, in: oldRows, name: "读取最近更新旧顺序")
                try consumeRows(oldRows, name: "读取最近更新旧顺序") { row in
                    oldSequence.append((text(row, 0), text(row, 1)))
                }

                let leadingIDs = Set(leading.map(\.id))
                let leadingToken = "leading-\(UUID().uuidString)"
                var rebuilt: [(comicID: String, syncToken: String)] = leading.map {
                    ($0.id, leadingToken)
                }
                if rebuilt.count < remoteTotal {
                    rebuilt.append(contentsOf: oldSequence.lazy
                        .filter { !leadingIDs.contains($0.comicID) }
                        .prefix(remoteTotal - rebuilt.count))
                }
                if rebuilt.count > remoteTotal {
                    rebuilt.removeLast(rebuilt.count - remoteTotal)
                }

                // A normal `mp` poll usually returns the same leading page.
                // Preserve those memberships verbatim in that case: metadata
                // above may still change, but rewriting thousands of positions
                // and sync tokens would only amplify SQLite writes.
                if oldSequence.map(\.comicID) != rebuilt.map(\.comicID) {
                    let clear = try prepare(
                        """
                        DELETE FROM favorite_memberships
                        WHERE account_id = ? AND folder_id = ? AND order_mode = ?
                        """,
                        name: "清理最近更新旧顺序"
                    )
                    defer { sqlite3_finalize(clear) }
                    try bind(accountID, to: 1, in: clear, name: "清理最近更新旧顺序")
                    try bind(folderID, to: 2, in: clear, name: "清理最近更新旧顺序")
                    try bind(sortOrder.rawValue, to: 3, in: clear, name: "清理最近更新旧顺序")
                    try stepDone(clear, name: "清理最近更新旧顺序")

                    let insert = try prepare(
                        """
                        INSERT INTO favorite_memberships
                            (account_id, folder_id, order_mode, comic_id, position, sync_token)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                        name: "保存最近更新连续顺序"
                    )
                    defer { sqlite3_finalize(insert) }
                    for (position, row) in rebuilt.enumerated() {
                        sqlite3_reset(insert)
                        sqlite3_clear_bindings(insert)
                        try bind(accountID, to: 1, in: insert, name: "保存最近更新连续顺序")
                        try bind(folderID, to: 2, in: insert, name: "保存最近更新连续顺序")
                        try bind(sortOrder.rawValue, to: 3, in: insert, name: "保存最近更新连续顺序")
                        try bind(row.comicID, to: 4, in: insert, name: "保存最近更新连续顺序")
                        try bind(position, to: 5, in: insert, name: "保存最近更新连续顺序")
                        try bind(row.syncToken, to: 6, in: insert, name: "保存最近更新连续顺序")
                        try stepDone(insert, name: "保存最近更新连续顺序")
                    }
                }

                let state = try prepare(
                    """
                    UPDATE favorite_sync_states SET total = ?
                    WHERE account_id = ? AND folder_id = ? AND order_mode = ?
                    """,
                    name: "更新最近更新同步总数"
                )
                defer { sqlite3_finalize(state) }
                try bind(remoteTotal, to: 1, in: state, name: "更新最近更新同步总数")
                try bind(accountID, to: 2, in: state, name: "更新最近更新同步总数")
                try bind(folderID, to: 3, in: state, name: "更新最近更新同步总数")
                try bind(sortOrder.rawValue, to: 4, in: state, name: "更新最近更新同步总数")
                try stepDone(state, name: "更新最近更新同步总数")
                try cleanupOrphanFavoriteComics(accountID: accountID)
            }
        }
    }

    /// Returns the number of cached memberships, not the remote total metadata.
    func favoriteMembershipCount(
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder = .added
    ) throws -> Int {
        try validateAccountID(accountID)
        guard !folderID.isEmpty else {
            throw OfflineLibraryDatabaseError.invalidData("收藏夹 ID 不能为空")
        }
        return try synchronized {
            try favoriteMembershipCountUnlocked(
                accountID: accountID,
                folderID: folderID,
                sortOrder: sortOrder
            )
        }
    }

    /// Marks one ordering namespace as requiring a complete refresh without
    /// deleting its readable cache. Call this immediately before starting a
    /// multi-page full sync. If the task is cancelled or the app terminates,
    /// `lastFavoriteSync` remains nil on the next launch while all previously
    /// committed memberships are still available offline.
    func beginFavoriteFullSync(
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder = .added
    ) throws {
        try validateAccountID(accountID)
        guard !folderID.isEmpty else {
            throw OfflineLibraryDatabaseError.invalidData("收藏夹 ID 不能为空")
        }

        try synchronized {
            try transaction {
                try ensureFavoriteFolder(
                    accountID: accountID,
                    folderID: folderID,
                    total: 0
                )
                let cachedTotal = try favoriteMembershipCountUnlocked(
                    accountID: accountID,
                    folderID: folderID,
                    sortOrder: sortOrder
                )
                let state = try prepare(
                    """
                    INSERT INTO favorite_sync_states
                        (account_id, folder_id, order_mode, total, last_synced_at)
                    VALUES (?, ?, ?, ?, 0)
                    ON CONFLICT(account_id, folder_id, order_mode) DO UPDATE SET
                        total = excluded.total,
                        last_synced_at = 0
                    """,
                    name: "开始收藏全量同步"
                )
                defer { sqlite3_finalize(state) }
                try bind(accountID, to: 1, in: state, name: "开始收藏全量同步")
                try bind(folderID, to: 2, in: state, name: "开始收藏全量同步")
                try bind(sortOrder.rawValue, to: 3, in: state, name: "开始收藏全量同步")
                try bind(cachedTotal, to: 4, in: state, name: "开始收藏全量同步")
                try stepDone(state, name: "开始收藏全量同步")

                if sortOrder == .added {
                    // Keep the downgrade/migration compatibility column from
                    // re-advertising an interrupted mr sync as complete.
                    let legacy = try prepare(
                        """
                        UPDATE favorite_folders SET last_synced_at = 0
                        WHERE account_id = ? AND folder_id = ?
                        """,
                        name: "标记默认收藏全量同步中断"
                    )
                    defer { sqlite3_finalize(legacy) }
                    try bind(accountID, to: 1, in: legacy, name: "标记默认收藏全量同步中断")
                    try bind(folderID, to: 2, in: legacy, name: "标记默认收藏全量同步中断")
                    try stepDone(legacy, name: "标记默认收藏全量同步中断")
                }
            }
        }
    }

    /// Merges one remote page into the cache. Old rows in that page's position
    /// range are replaced immediately, while other pages remain available until
    /// `finishFavoriteSync` confirms the complete refresh.
    func cacheFavoritePage(
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder = .added,
        page: Int,
        pageSize: Int,
        result: FavoritePage,
        syncToken: String,
        at: Date = .now
    ) throws {
        try validateAccountID(accountID)
        guard !folderID.isEmpty else {
            throw OfflineLibraryDatabaseError.invalidData("收藏夹 ID 不能为空")
        }
        guard page > 0, pageSize > 0 else {
            throw OfflineLibraryDatabaseError.invalidData("收藏分页参数必须大于 0")
        }
        guard result.comics.count <= pageSize else {
            throw OfflineLibraryDatabaseError.invalidData(
                "收藏页返回 \(result.comics.count) 条，超过 pageSize \(pageSize)"
            )
        }
        guard result.total >= 0 else {
            throw OfflineLibraryDatabaseError.invalidData("收藏页总数不能为负数")
        }
        guard !syncToken.isEmpty else {
            throw OfflineLibraryDatabaseError.invalidData("收藏同步 token 不能为空")
        }
        let (pageOffset, overflow) = (page - 1).multipliedReportingOverflow(by: pageSize)
        let (pageUpperBound, upperBoundOverflow) = pageOffset.addingReportingOverflow(pageSize)
        guard !overflow, !upperBoundOverflow else {
            throw OfflineLibraryDatabaseError.invalidData("收藏分页偏移量溢出")
        }

        try synchronized {
            try transaction {
                let folder = result.folders.first(where: { $0.id == folderID })
                if let folder {
                    try upsertFavoriteFolder(
                        accountID: accountID,
                        folderID: folderID,
                        name: folder.name,
                        sort: result.folders.firstIndex(where: { $0.id == folderID }) ?? 0,
                        total: result.total
                    )
                } else {
                    try ensureFavoriteFolder(
                        accountID: accountID,
                        folderID: folderID,
                        total: result.total
                    )
                    try updateFavoriteFolderTotal(
                        accountID: accountID,
                        folderID: folderID,
                        total: result.total
                    )
                }

                let clearRange = try prepare(
                    """
                    DELETE FROM favorite_memberships
                    WHERE account_id = ? AND folder_id = ? AND order_mode = ?
                      AND position >= ? AND position < ?
                    """,
                    name: "替换收藏分页"
                )
                defer { sqlite3_finalize(clearRange) }
                try bind(accountID, to: 1, in: clearRange, name: "替换收藏分页")
                try bind(folderID, to: 2, in: clearRange, name: "替换收藏分页")
                try bind(sortOrder.rawValue, to: 3, in: clearRange, name: "替换收藏分页")
                try bind(pageOffset, to: 4, in: clearRange, name: "替换收藏分页")
                try bind(pageUpperBound, to: 5, in: clearRange, name: "替换收藏分页")
                try stepDone(clearRange, name: "替换收藏分页")

                for (offset, comic) in result.comics.enumerated() {
                    try upsertFavoriteComic(accountID: accountID, comic: comic, updatedAt: at)
                    let membership = try prepare(
                        """
                        INSERT INTO favorite_memberships
                            (account_id, folder_id, order_mode, comic_id, position, sync_token)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(account_id, folder_id, order_mode, comic_id) DO UPDATE SET
                            position = excluded.position,
                            sync_token = excluded.sync_token
                        """,
                        name: "保存收藏漫画顺序"
                    )
                    defer { sqlite3_finalize(membership) }
                    try bind(accountID, to: 1, in: membership, name: "保存收藏漫画顺序")
                    try bind(folderID, to: 2, in: membership, name: "保存收藏漫画顺序")
                    try bind(sortOrder.rawValue, to: 3, in: membership, name: "保存收藏漫画顺序")
                    try bind(comic.id, to: 4, in: membership, name: "保存收藏漫画顺序")
                    try bind(pageOffset + offset, to: 5, in: membership, name: "保存收藏漫画顺序")
                    try bind(syncToken, to: 6, in: membership, name: "保存收藏漫画顺序")
                    try stepDone(membership, name: "保存收藏漫画顺序")
                }
                // Do not clean orphan metadata between pages. During a full
                // reorder a comic may move from the page just replaced to a
                // page not written yet; deleting it here also loses its cover
                // cache path. finishFavoriteSync performs cleanup atomically.
            }
        }
    }

    func cachedFavoritePage(
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder = .added,
        offset: Int,
        limit: Int
    ) throws -> CachedFavoritePage {
        try validateAccountID(accountID)
        guard !folderID.isEmpty else {
            throw OfflineLibraryDatabaseError.invalidData("收藏夹 ID 不能为空")
        }
        guard offset >= 0, limit > 0 else {
            throw OfflineLibraryDatabaseError.invalidData("收藏缓存 offset 必须非负且 limit 必须大于 0")
        }

        return try synchronized {
            try transaction(begin: "BEGIN DEFERRED") {
                // 收藏夹元数据里的 total 可来自刚请求的服务端 badge；内容页必须以
                // 当前 SQLite 成员数量为准，避免增量模式下显示尚未落库或已删除的数量。
                let total = try favoriteMembershipCountUnlocked(
                    accountID: accountID,
                    folderID: folderID,
                    sortOrder: sortOrder
                )
                var rows: [(id: String, name: String, coverRelativePath: String?)] = []
                let statement = try prepare(
                    """
                    SELECT c.comic_id, c.name, c.cover_relative_path
                    FROM favorite_memberships m
                    JOIN favorite_comics c
                      ON c.account_id = m.account_id AND c.comic_id = m.comic_id
                    WHERE m.account_id = ? AND m.folder_id = ? AND m.order_mode = ?
                    ORDER BY m.position, m.comic_id
                    LIMIT ? OFFSET ?
                    """,
                    name: "读取收藏漫画缓存"
                )
                defer { sqlite3_finalize(statement) }
                try bind(accountID, to: 1, in: statement, name: "读取收藏漫画缓存")
                try bind(folderID, to: 2, in: statement, name: "读取收藏漫画缓存")
                try bind(sortOrder.rawValue, to: 3, in: statement, name: "读取收藏漫画缓存")
                try bind(limit, to: 4, in: statement, name: "读取收藏漫画缓存")
                try bind(offset, to: 5, in: statement, name: "读取收藏漫画缓存")
                try consumeRows(statement, name: "读取收藏漫画缓存") { row in
                    rows.append((text(row, 0), text(row, 1), optionalText(row, 2)))
                }

                let authors = try cachedFavoriteNames(
                    table: "favorite_comic_authors",
                    accountID: accountID,
                    folderID: folderID,
                    sortOrder: sortOrder,
                    offset: offset,
                    limit: limit,
                    operationName: "读取收藏作者缓存"
                )
                let tags = try cachedFavoriteNames(
                    table: "favorite_comic_tags",
                    accountID: accountID,
                    folderID: folderID,
                    sortOrder: sortOrder,
                    offset: offset,
                    limit: limit,
                    operationName: "读取收藏标签缓存"
                )
                let comics = rows.map { row in
                    ComicSummary(
                        id: row.id,
                        name: row.name,
                        authors: authors[row.id] ?? [],
                        tags: tags[row.id] ?? []
                    )
                }
                let coverRelativePaths = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                    row.coverRelativePath.map { (row.id, $0) }
                })
                return CachedFavoritePage(
                    total: total,
                    comics: comics,
                    coverRelativePaths: coverRelativePaths
                )
            }
        }
    }

    func setFavoriteComicCoverRelativePath(
        accountID: String,
        comicID: String,
        relativePath: String?
    ) throws {
        try validateAccountID(accountID)
        guard !comicID.isEmpty else {
            throw OfflineLibraryDatabaseError.invalidData("收藏漫画 ID 不能为空")
        }
        if let relativePath, !JMComicCoverCacheStorage.isSafeRelativePath(relativePath) {
            throw OfflineLibraryDatabaseError.invalidData("收藏封面缓存路径不安全: \(relativePath)")
        }
        try synchronized {
            try transaction {
                let statement = try prepare(
                    relativePath == nil
                        ? """
                          UPDATE favorite_comics SET cover_relative_path = NULL
                          WHERE account_id = ? AND comic_id = ?
                          """
                        : """
                          UPDATE favorite_comics SET cover_relative_path = ?
                          WHERE account_id = ? AND comic_id = ?
                          """,
                    name: "保存收藏封面路径"
                )
                defer { sqlite3_finalize(statement) }
                if let relativePath {
                    try bind(relativePath, to: 1, in: statement, name: "保存收藏封面路径")
                    try bind(accountID, to: 2, in: statement, name: "保存收藏封面路径")
                    try bind(comicID, to: 3, in: statement, name: "保存收藏封面路径")
                } else {
                    try bind(accountID, to: 1, in: statement, name: "保存收藏封面路径")
                    try bind(comicID, to: 2, in: statement, name: "保存收藏封面路径")
                }
                try stepDone(statement, name: "保存收藏封面路径")
                guard sqlite3_changes(try handle()) > 0 else {
                    throw OfflineLibraryDatabaseError.invalidData(
                        "找不到账户 \(accountID) 的收藏漫画 \(comicID)"
                    )
                }
            }
        }
    }

    func favoriteComicCoverRelativePath(accountID: String, comicID: String) throws -> String? {
        try validateAccountID(accountID)
        guard !comicID.isEmpty else {
            throw OfflineLibraryDatabaseError.invalidData("收藏漫画 ID 不能为空")
        }
        return try synchronized {
            let statement = try prepare(
                """
                SELECT cover_relative_path FROM favorite_comics
                WHERE account_id = ? AND comic_id = ?
                """,
                name: "读取收藏封面路径"
            )
            defer { sqlite3_finalize(statement) }
            try bind(accountID, to: 1, in: statement, name: "读取收藏封面路径")
            try bind(comicID, to: 2, in: statement, name: "读取收藏封面路径")
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                return optionalText(statement, 0)
            case SQLITE_DONE:
                return nil
            default:
                throw currentError(name: "读取收藏封面路径")
            }
        }
    }

    /// The history store owns this table's schema, but all cover owners share
    /// the same visible SQLite file. These narrow accessors let the common cover
    /// coordinator update the history reference without opening another ad-hoc
    /// connection from a SwiftUI view.
    func setReadingHistoryCoverRelativePath(
        comicID: String,
        relativePath: String?
    ) throws {
        guard !comicID.isEmpty else {
            throw OfflineLibraryDatabaseError.invalidData("阅读历史漫画 ID 不能为空")
        }
        if let relativePath, !JMComicCoverCacheStorage.isSafeRelativePath(relativePath) {
            throw OfflineLibraryDatabaseError.invalidData("阅读历史封面缓存路径不安全: \(relativePath)")
        }
        try synchronized {
            guard try tableHasColumn("reading_history", column: "cover_relative_path") else {
                throw OfflineLibraryDatabaseError.invalidData("阅读历史封面索引尚未初始化")
            }
            let statement = try prepare(
                "UPDATE reading_history SET cover_relative_path = ? WHERE comic_id = ?",
                name: "保存阅读历史封面路径"
            )
            defer { sqlite3_finalize(statement) }
            if let relativePath {
                try bind(relativePath, to: 1, in: statement, name: "保存阅读历史封面路径")
            } else {
                guard sqlite3_bind_null(statement, 1) == SQLITE_OK else {
                    throw currentError(name: "保存阅读历史封面路径")
                }
            }
            try bind(comicID, to: 2, in: statement, name: "保存阅读历史封面路径")
            try stepDone(statement, name: "保存阅读历史封面路径")
            guard sqlite3_changes(try handle()) > 0 else {
                throw OfflineLibraryDatabaseError.invalidData("找不到阅读历史漫画 \(comicID)")
            }
        }
    }

    func readingHistoryCoverRelativePath(comicID: String) throws -> String? {
        guard !comicID.isEmpty else {
            throw OfflineLibraryDatabaseError.invalidData("阅读历史漫画 ID 不能为空")
        }
        return try synchronized {
            guard try tableHasColumn("reading_history", column: "cover_relative_path") else {
                return nil
            }
            let statement = try prepare(
                "SELECT cover_relative_path FROM reading_history WHERE comic_id = ?",
                name: "读取阅读历史封面路径"
            )
            defer { sqlite3_finalize(statement) }
            try bind(comicID, to: 1, in: statement, name: "读取阅读历史封面路径")
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let path = optionalText(statement, 0),
                      JMComicCoverCacheStorage.isSafeRelativePath(path) else { return nil }
                return path
            case SQLITE_DONE:
                return nil
            default:
                throw currentError(name: "读取阅读历史封面路径")
            }
        }
    }

    /// A corrupt shared file must not leave downloads, favorites, or history
    /// rows pointing at bytes that have been removed.
    func clearCoverRelativePathReferences(_ relativePath: String) throws {
        guard JMComicCoverCacheStorage.isSafeRelativePath(relativePath) else {
            throw OfflineLibraryDatabaseError.invalidData("封面缓存路径不安全: \(relativePath)")
        }
        try synchronized {
            try transaction {
                var updates = [
                    (
                        "UPDATE comics SET cover_relative_path = NULL WHERE cover_relative_path = ?",
                        "清理离线封面引用"
                    ),
                    (
                        "UPDATE favorite_comics SET cover_relative_path = NULL WHERE cover_relative_path = ?",
                        "清理收藏封面引用"
                    )
                ]
                if try tableHasColumn("reading_history", column: "cover_relative_path") {
                    updates.append((
                        "UPDATE reading_history SET cover_relative_path = NULL WHERE cover_relative_path = ?",
                        "清理阅读历史封面引用"
                    ))
                }
                for (sql, name) in updates {
                    let statement = try prepare(sql, name: name)
                    defer { sqlite3_finalize(statement) }
                    try bind(relativePath, to: 1, in: statement, name: name)
                    try stepDone(statement, name: name)
                }
            }
        }
    }

    func isCoverRelativePathReferenced(_ relativePath: String) throws -> Bool {
        guard JMComicCoverCacheStorage.isSafeRelativePath(relativePath) else {
            throw OfflineLibraryDatabaseError.invalidData("封面缓存路径不安全: \(relativePath)")
        }
        return try synchronized {
            let includesHistory = try tableHasColumn(
                "reading_history",
                column: "cover_relative_path"
            )
            let statement = try prepare(
                includesHistory ? """
                SELECT EXISTS(
                    SELECT 1 FROM comics WHERE cover_relative_path = ?
                    UNION ALL
                    SELECT 1 FROM favorite_comics WHERE cover_relative_path = ?
                    UNION ALL
                    SELECT 1 FROM reading_history WHERE cover_relative_path = ?
                )
                """ : """
                SELECT EXISTS(
                    SELECT 1 FROM comics WHERE cover_relative_path = ?
                    UNION ALL
                    SELECT 1 FROM favorite_comics WHERE cover_relative_path = ?
                )
                """,
                name: "检查封面缓存引用"
            )
            defer { sqlite3_finalize(statement) }
            try bind(relativePath, to: 1, in: statement, name: "检查封面缓存引用")
            try bind(relativePath, to: 2, in: statement, name: "检查封面缓存引用")
            if includesHistory {
                try bind(relativePath, to: 3, in: statement, name: "检查封面缓存引用")
            }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw currentError(name: "检查封面缓存引用")
            }
            return sqlite3_column_int(statement, 0) != 0
        }
    }

    /// Commits a complete multi-page refresh and removes rows not seen under
    /// this token. Until this call, unsynced old pages remain available offline.
    func finishFavoriteSync(
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder = .added,
        syncToken: String,
        total: Int,
        at: Date = .now
    ) throws {
        try validateAccountID(accountID)
        guard !folderID.isEmpty, !syncToken.isEmpty else {
            throw OfflineLibraryDatabaseError.invalidData("收藏夹 ID 和同步 token 不能为空")
        }
        guard total >= 0 else {
            throw OfflineLibraryDatabaseError.invalidData("收藏总数不能为负数")
        }
        try synchronized {
            try transaction {
                try ensureFavoriteFolder(
                    accountID: accountID,
                    folderID: folderID,
                    total: total
                )
                let syncedItemCount = try favoriteSyncItemCount(
                    accountID: accountID,
                    folderID: folderID,
                    sortOrder: sortOrder,
                    syncToken: syncToken
                )
                guard syncedItemCount == total else {
                    throw OfflineLibraryDatabaseError.invalidData(
                        "收藏夹 \(folderID) 同步不完整：token \(syncToken) 只覆盖 "
                            + "\(syncedItemCount) / \(total) 本漫画"
                    )
                }
                let removeStale = try prepare(
                    """
                    DELETE FROM favorite_memberships
                    WHERE account_id = ? AND folder_id = ? AND order_mode = ?
                      AND sync_token <> ?
                    """,
                    name: "清理过期收藏缓存"
                )
                defer { sqlite3_finalize(removeStale) }
                try bind(accountID, to: 1, in: removeStale, name: "清理过期收藏缓存")
                try bind(folderID, to: 2, in: removeStale, name: "清理过期收藏缓存")
                try bind(sortOrder.rawValue, to: 3, in: removeStale, name: "清理过期收藏缓存")
                try bind(syncToken, to: 4, in: removeStale, name: "清理过期收藏缓存")
                try stepDone(removeStale, name: "清理过期收藏缓存")

                let state = try prepare(
                    """
                    INSERT INTO favorite_sync_states
                        (account_id, folder_id, order_mode, total, last_synced_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(account_id, folder_id, order_mode) DO UPDATE SET
                        total = excluded.total,
                        last_synced_at = excluded.last_synced_at
                    """,
                    name: "完成收藏同步"
                )
                defer { sqlite3_finalize(state) }
                try bind(accountID, to: 1, in: state, name: "完成收藏同步")
                try bind(folderID, to: 2, in: state, name: "完成收藏同步")
                try bind(sortOrder.rawValue, to: 3, in: state, name: "完成收藏同步")
                try bind(total, to: 4, in: state, name: "完成收藏同步")
                try bind(at.timeIntervalSince1970, to: 5, in: state, name: "完成收藏同步")
                try stepDone(state, name: "完成收藏同步")

                try updateFavoriteFolderTotal(
                    accountID: accountID,
                    folderID: folderID,
                    total: total
                )
                if sortOrder == .added {
                    // Keep the legacy column current for downgrade-safe
                    // migration; current reads use favorite_sync_states.
                    let legacy = try prepare(
                        """
                        UPDATE favorite_folders SET last_synced_at = ?
                        WHERE account_id = ? AND folder_id = ?
                        """,
                        name: "更新默认收藏同步时间"
                    )
                    defer { sqlite3_finalize(legacy) }
                    try bind(at.timeIntervalSince1970, to: 1, in: legacy, name: "更新默认收藏同步时间")
                    try bind(accountID, to: 2, in: legacy, name: "更新默认收藏同步时间")
                    try bind(folderID, to: 3, in: legacy, name: "更新默认收藏同步时间")
                    try stepDone(legacy, name: "更新默认收藏同步时间")
                }
                try cleanupOrphanFavoriteComics(accountID: accountID)
            }
        }
    }

    func lastFavoriteSync(
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder = .added
    ) throws -> Date? {
        try validateAccountID(accountID)
        return try synchronized {
            let statement = try prepare(
                """
                SELECT last_synced_at FROM favorite_sync_states
                WHERE account_id = ? AND folder_id = ? AND order_mode = ?
                """,
                name: "读取收藏同步时间"
            )
            defer { sqlite3_finalize(statement) }
            try bind(accountID, to: 1, in: statement, name: "读取收藏同步时间")
            try bind(folderID, to: 2, in: statement, name: "读取收藏同步时间")
            try bind(sortOrder.rawValue, to: 3, in: statement, name: "读取收藏同步时间")
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let timestamp = sqlite3_column_double(statement, 0)
                return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
            case SQLITE_DONE:
                return nil
            default:
                throw currentError(name: "读取收藏同步时间")
            }
        }
    }

    func clearFavoriteCache(accountID: String) throws {
        try validateAccountID(accountID)
        try synchronized {
            try transaction {
                let folders = try prepare(
                    "DELETE FROM favorite_folders WHERE account_id = ?",
                    name: "清空账户收藏夹缓存"
                )
                defer { sqlite3_finalize(folders) }
                try bind(accountID, to: 1, in: folders, name: "清空账户收藏夹缓存")
                try stepDone(folders, name: "清空账户收藏夹缓存")

                let comics = try prepare(
                    "DELETE FROM favorite_comics WHERE account_id = ?",
                    name: "清空账户收藏漫画缓存"
                )
                defer { sqlite3_finalize(comics) }
                try bind(accountID, to: 1, in: comics, name: "清空账户收藏漫画缓存")
                try stepDone(comics, name: "清空账户收藏漫画缓存")
            }
        }
    }

    // MARK: - Search history and lightweight comic titles

    func searchHistory(limit: Int = 20) throws -> [SearchHistoryEntry] {
        guard (1...100).contains(limit) else {
            throw OfflineLibraryDatabaseError.invalidData("搜索历史 limit 必须在 1...100")
        }
        return try synchronized {
            var entries: [SearchHistoryEntry] = []
            let statement = try prepare(
                """
                SELECT query_key, display_query, last_searched_at
                FROM search_history
                ORDER BY use_order DESC
                LIMIT ?
                """,
                name: "读取搜索历史"
            )
            defer { sqlite3_finalize(statement) }
            try bind(limit, to: 1, in: statement, name: "读取搜索历史")
            try consumeRows(statement, name: "读取搜索历史") { row in
                entries.append(SearchHistoryEntry(
                    queryKey: text(row, 0),
                    query: text(row, 1),
                    lastSearchedAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 2))
                ))
            }
            return entries
        }
    }

    func recordSearchQuery(
        _ rawQuery: String,
        at date: Date = .now,
        maximumEntries: Int = 50
    ) throws {
        guard let normalized = SearchHistoryNormalization.value(from: rawQuery) else { return }
        guard (1...500).contains(maximumEntries) else {
            throw OfflineLibraryDatabaseError.invalidData("搜索历史上限必须在 1...500")
        }
        try synchronized {
            try transaction {
                let upsert = try prepare(
                    """
                    INSERT INTO search_history
                        (query_key, display_query, last_searched_at, use_order)
                    VALUES (
                        ?, ?, ?,
                        (SELECT COALESCE(MAX(use_order), 0) + 1 FROM search_history)
                    )
                    ON CONFLICT(query_key) DO UPDATE SET
                        display_query = excluded.display_query,
                        last_searched_at = excluded.last_searched_at,
                        use_order = excluded.use_order
                    """,
                    name: "保存搜索历史"
                )
                defer { sqlite3_finalize(upsert) }
                try bind(normalized.key, to: 1, in: upsert, name: "保存搜索历史")
                try bind(normalized.display, to: 2, in: upsert, name: "保存搜索历史")
                try bind(date.timeIntervalSince1970, to: 3, in: upsert, name: "保存搜索历史")
                try stepDone(upsert, name: "保存搜索历史")

                let trim = try prepare(
                    """
                    DELETE FROM search_history
                    WHERE query_key IN (
                        SELECT query_key FROM search_history
                        ORDER BY use_order DESC
                        LIMIT -1 OFFSET ?
                    )
                    """,
                    name: "限制搜索历史数量"
                )
                defer { sqlite3_finalize(trim) }
                try bind(maximumEntries, to: 1, in: trim, name: "限制搜索历史数量")
                try stepDone(trim, name: "限制搜索历史数量")
            }
        }
    }

    func deleteSearchQuery(_ rawQuery: String) throws {
        guard let normalized = SearchHistoryNormalization.value(from: rawQuery) else { return }
        try synchronized {
            let statement = try prepare(
                "DELETE FROM search_history WHERE query_key = ?",
                name: "删除搜索历史"
            )
            defer { sqlite3_finalize(statement) }
            try bind(normalized.key, to: 1, in: statement, name: "删除搜索历史")
            try stepDone(statement, name: "删除搜索历史")
        }
    }

    func clearSearchHistory() throws {
        try synchronized {
            try execute("DELETE FROM search_history", name: "清空搜索历史")
        }
    }

    func cachedComicTitles(comicIDs: [String]) throws -> [String: String] {
        let ids = Array(Set(comicIDs.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()
        guard !ids.isEmpty else { return [:] }

        return try synchronized {
            let includesHistory = try tableHasColumn("reading_history", column: "name")
            let sql = includesHistory ? """
                SELECT name FROM (
                    SELECT name, 0 AS source_priority, updated_at AS recency
                    FROM comic_title_cache WHERE comic_id = ?
                    UNION ALL
                    SELECT name, 1, updated_at FROM comics WHERE id = ?
                    UNION ALL
                    SELECT name, 2, updated_at FROM favorite_comics WHERE comic_id = ?
                    UNION ALL
                    SELECT name, 3, last_viewed_at FROM reading_history WHERE comic_id = ?
                )
                WHERE TRIM(name) <> ''
                ORDER BY source_priority, recency DESC
                LIMIT 1
                """ : """
                SELECT name FROM (
                    SELECT name, 0 AS source_priority, updated_at AS recency
                    FROM comic_title_cache WHERE comic_id = ?
                    UNION ALL
                    SELECT name, 1, updated_at FROM comics WHERE id = ?
                    UNION ALL
                    SELECT name, 2, updated_at FROM favorite_comics WHERE comic_id = ?
                )
                WHERE TRIM(name) <> ''
                ORDER BY source_priority, recency DESC
                LIMIT 1
                """
            let statement = try prepare(sql, name: "读取漫画名称缓存")
            defer { sqlite3_finalize(statement) }
            var values: [String: String] = [:]
            for id in ids {
                guard sqlite3_reset(statement) == SQLITE_OK,
                      sqlite3_clear_bindings(statement) == SQLITE_OK else {
                    throw currentError(name: "重置漫画名称缓存查询")
                }
                let bindingCount = includesHistory ? 4 : 3
                for index in 1...bindingCount {
                    try bind(id, to: Int32(index), in: statement, name: "读取漫画名称缓存")
                }
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    let title = text(statement, 0)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty { values[id] = title }
                case SQLITE_DONE:
                    break
                default:
                    throw currentError(name: "读取漫画名称缓存")
                }
            }
            return values
        }
    }

    func cacheComicTitles(_ titles: [String: String], at date: Date = .now) throws {
        let values = titles.compactMap { id, name -> (String, String)? in
            let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedID.isEmpty, !normalizedName.isEmpty else { return nil }
            return (normalizedID, normalizedName)
        }.sorted { $0.0 < $1.0 }
        guard !values.isEmpty else { return }

        try synchronized {
            try transaction {
                let statement = try prepare(
                    """
                    INSERT INTO comic_title_cache (comic_id, name, updated_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(comic_id) DO UPDATE SET
                        name = excluded.name,
                        updated_at = excluded.updated_at
                    """,
                    name: "保存漫画名称缓存"
                )
                defer { sqlite3_finalize(statement) }
                for (id, name) in values {
                    guard sqlite3_reset(statement) == SQLITE_OK,
                          sqlite3_clear_bindings(statement) == SQLITE_OK else {
                        throw currentError(name: "重置漫画名称缓存写入")
                    }
                    try bind(id, to: 1, in: statement, name: "保存漫画名称缓存")
                    try bind(name, to: 2, in: statement, name: "保存漫画名称缓存")
                    try bind(date.timeIntervalSince1970, to: 3, in: statement, name: "保存漫画名称缓存")
                    try stepDone(statement, name: "保存漫画名称缓存")
                }
            }
        }
    }

    // MARK: - Schema

    private func createSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS comics (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                storage_directory_name TEXT NOT NULL,
                cover_relative_path TEXT,
                added_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS authors (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL UNIQUE
            );

            CREATE TABLE IF NOT EXISTS tags (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL UNIQUE
            );

            CREATE TABLE IF NOT EXISTS comic_authors (
                comic_id TEXT NOT NULL,
                author_id INTEGER NOT NULL,
                position INTEGER NOT NULL,
                PRIMARY KEY (comic_id, author_id),
                FOREIGN KEY (comic_id) REFERENCES comics(id) ON DELETE CASCADE,
                FOREIGN KEY (author_id) REFERENCES authors(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS comic_tags (
                comic_id TEXT NOT NULL,
                tag_id INTEGER NOT NULL,
                position INTEGER NOT NULL,
                PRIMARY KEY (comic_id, tag_id),
                FOREIGN KEY (comic_id) REFERENCES comics(id) ON DELETE CASCADE,
                FOREIGN KEY (tag_id) REFERENCES tags(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS chapters (
                id TEXT PRIMARY KEY NOT NULL,
                comic_id TEXT NOT NULL,
                title TEXT NOT NULL,
                sort INTEGER NOT NULL,
                expected_page_count INTEGER NOT NULL CHECK (expected_page_count >= 0),
                FOREIGN KEY (comic_id) REFERENCES comics(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS pages (
                chapter_id TEXT NOT NULL,
                page_index INTEGER NOT NULL CHECK (page_index >= 0),
                global_ordinal INTEGER NOT NULL CHECK (global_ordinal > 0),
                relative_path TEXT NOT NULL,
                completed INTEGER NOT NULL DEFAULT 0 CHECK (completed IN (0, 1)),
                PRIMARY KEY (chapter_id, page_index),
                UNIQUE (relative_path),
                FOREIGN KEY (chapter_id) REFERENCES chapters(id) ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS idx_comic_authors_order
                ON comic_authors(comic_id, position);
            CREATE INDEX IF NOT EXISTS idx_comic_tags_order
                ON comic_tags(comic_id, position);
            CREATE INDEX IF NOT EXISTS idx_chapters_comic_sort
                ON chapters(comic_id, sort, id);
            CREATE INDEX IF NOT EXISTS idx_pages_chapter_completed_page
                ON pages(chapter_id, completed, page_index);
            CREATE INDEX IF NOT EXISTS idx_pages_chapter_ordinal
                ON pages(chapter_id, global_ordinal);

            CREATE TABLE IF NOT EXISTS favorite_folders (
                account_id TEXT NOT NULL,
                folder_id TEXT NOT NULL,
                name TEXT NOT NULL,
                sort INTEGER NOT NULL,
                total INTEGER NOT NULL DEFAULT 0 CHECK (total >= 0),
                last_synced_at REAL NOT NULL DEFAULT 0,
                PRIMARY KEY (account_id, folder_id)
            );

            CREATE TABLE IF NOT EXISTS favorite_comics (
                account_id TEXT NOT NULL,
                comic_id TEXT NOT NULL,
                name TEXT NOT NULL,
                cover_relative_path TEXT,
                updated_at REAL NOT NULL,
                PRIMARY KEY (account_id, comic_id)
            );

            CREATE TABLE IF NOT EXISTS favorite_comic_authors (
                account_id TEXT NOT NULL,
                comic_id TEXT NOT NULL,
                position INTEGER NOT NULL,
                name TEXT NOT NULL,
                PRIMARY KEY (account_id, comic_id, position),
                FOREIGN KEY (account_id, comic_id)
                    REFERENCES favorite_comics(account_id, comic_id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS favorite_comic_tags (
                account_id TEXT NOT NULL,
                comic_id TEXT NOT NULL,
                position INTEGER NOT NULL,
                name TEXT NOT NULL,
                PRIMARY KEY (account_id, comic_id, position),
                FOREIGN KEY (account_id, comic_id)
                    REFERENCES favorite_comics(account_id, comic_id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS favorite_memberships (
                account_id TEXT NOT NULL,
                folder_id TEXT NOT NULL,
                order_mode TEXT NOT NULL CHECK (order_mode IN ('mr', 'mp')),
                comic_id TEXT NOT NULL,
                position INTEGER NOT NULL,
                sync_token TEXT NOT NULL,
                PRIMARY KEY (account_id, folder_id, order_mode, comic_id),
                FOREIGN KEY (account_id, folder_id)
                    REFERENCES favorite_folders(account_id, folder_id) ON DELETE CASCADE,
                FOREIGN KEY (account_id, comic_id)
                    REFERENCES favorite_comics(account_id, comic_id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS favorite_sync_states (
                account_id TEXT NOT NULL,
                folder_id TEXT NOT NULL,
                order_mode TEXT NOT NULL CHECK (order_mode IN ('mr', 'mp')),
                total INTEGER NOT NULL DEFAULT 0 CHECK (total >= 0),
                last_synced_at REAL NOT NULL DEFAULT 0,
                PRIMARY KEY (account_id, folder_id, order_mode),
                FOREIGN KEY (account_id, folder_id)
                    REFERENCES favorite_folders(account_id, folder_id) ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS idx_favorite_folders_account_sort
                ON favorite_folders(account_id, sort, folder_id);

            CREATE TABLE IF NOT EXISTS search_history (
                query_key TEXT PRIMARY KEY NOT NULL,
                display_query TEXT NOT NULL,
                last_searched_at REAL NOT NULL,
                use_order INTEGER NOT NULL UNIQUE
            );

            CREATE INDEX IF NOT EXISTS idx_search_history_recent
                ON search_history(use_order DESC);

            CREATE TABLE IF NOT EXISTS comic_title_cache (
                comic_id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                updated_at REAL NOT NULL
            );
            """,
            name: "创建离线索引表"
        )
        try ensureComicAddedAtColumn()
        try ensureComicCoverRelativePathColumn()
        try ensureFavoriteComicCoverRelativePathColumn()
        try ensureFavoriteMembershipOrderModeSchema()
        try ensureCoverReferenceIndexes()

        // Publish the schema version only after every idempotent migration has
        // succeeded, and never downgrade a database created by a future build.
        var schemaVersion = 0
        try query("PRAGMA user_version", name: "读取数据库版本") { row in
            schemaVersion = Int(sqlite3_column_int64(row, 0))
        }
        if schemaVersion < 5 {
            try execute("PRAGMA user_version = 5", name: "更新数据库版本")
        }
    }

    /// Databases created before the two server sort orders were exposed stored
    /// one membership list per folder. That list is the upstream default `mr`.
    /// Rebuilding the table is required because `order_mode` is also part of the
    /// primary key; adding only a nullable column would still make `mr` and `mp`
    /// overwrite one another.
    private func ensureFavoriteMembershipOrderModeSchema() throws {
        var hasOrderMode = false
        try query(
            "PRAGMA table_info(favorite_memberships)",
            name: "检查收藏排序命名空间"
        ) { row in
            if text(row, 1) == "order_mode" { hasOrderMode = true }
        }

        if !hasOrderMode {
            try transaction {
                try execute(
                    """
                    CREATE TABLE favorite_memberships_ordered (
                        account_id TEXT NOT NULL,
                        folder_id TEXT NOT NULL,
                        order_mode TEXT NOT NULL CHECK (order_mode IN ('mr', 'mp')),
                        comic_id TEXT NOT NULL,
                        position INTEGER NOT NULL,
                        sync_token TEXT NOT NULL,
                        PRIMARY KEY (account_id, folder_id, order_mode, comic_id),
                        FOREIGN KEY (account_id, folder_id)
                            REFERENCES favorite_folders(account_id, folder_id) ON DELETE CASCADE,
                        FOREIGN KEY (account_id, comic_id)
                            REFERENCES favorite_comics(account_id, comic_id) ON DELETE CASCADE
                    );
                    INSERT INTO favorite_memberships_ordered
                        (account_id, folder_id, order_mode, comic_id, position, sync_token)
                    SELECT account_id, folder_id, 'mr', comic_id, position, sync_token
                    FROM favorite_memberships;
                    DROP TABLE favorite_memberships;
                    ALTER TABLE favorite_memberships_ordered RENAME TO favorite_memberships;
                    """,
                    name: "迁移收藏排序命名空间"
                )
            }
        }

        // These indexes are intentionally created after the migration. Trying
        // to reference order_mode in the initial schema batch would make an old
        // database fail before it had a chance to rebuild the table.
        try execute(
            """
            CREATE INDEX IF NOT EXISTS idx_favorite_memberships_page
                ON favorite_memberships(
                    account_id, folder_id, order_mode, position, comic_id
                );
            CREATE INDEX IF NOT EXISTS idx_favorite_memberships_sync
                ON favorite_memberships(
                    account_id, folder_id, order_mode, sync_token
                );
            CREATE INDEX IF NOT EXISTS idx_favorite_memberships_comic
                ON favorite_memberships(account_id, comic_id, folder_id);
            """,
            name: "创建收藏排序命名空间索引"
        )

        // The old schema recorded completion only on the folder row. Trust that
        // timestamp only when the cached membership sequence itself proves that
        // the full sync committed: exact count, contiguous positions, and no
        // more than one non-incremental full-sync token. Corrupt/partial caches
        // deliberately stay uninitialised so the next launch rebuilds them.
        try execute(
            """
            INSERT OR IGNORE INTO favorite_sync_states
                (account_id, folder_id, order_mode, total, last_synced_at)
            SELECT f.account_id, f.folder_id, 'mr', f.total, f.last_synced_at
            FROM favorite_folders AS f
            LEFT JOIN (
                SELECT account_id,
                       folder_id,
                       COUNT(*) AS membership_count,
                       COUNT(DISTINCT position) AS position_count,
                       MIN(position) AS min_position,
                       MAX(position) AS max_position,
                       COUNT(DISTINCT CASE
                           WHEN sync_token <> 'incremental' THEN sync_token
                       END) AS full_token_count
                FROM favorite_memberships
                WHERE order_mode = 'mr'
                GROUP BY account_id, folder_id
            ) AS m
              ON m.account_id = f.account_id AND m.folder_id = f.folder_id
            WHERE f.last_synced_at > 0
              AND COALESCE(m.membership_count, 0) = f.total
              AND (
                  f.total = 0 OR (
                      COALESCE(m.position_count, 0) = f.total
                      AND m.min_position = 0
                      AND m.max_position = f.total - 1
                  )
              )
              AND COALESCE(m.full_token_count, 0) <= 1;
            """,
            name: "迁移收藏全量同步状态"
        )
    }

    /// Adds a reliable first-added timestamp to databases created by builds
    /// 1–4. This migration is deliberately independent of `user_version` so it
    /// can coexist with other feature-table migrations in the same release.
    private func ensureComicAddedAtColumn() throws {
        var hasAddedAt = false
        try query("PRAGMA table_info(comics)", name: "检查离线漫画加入时间") { row in
            if text(row, 1) == "added_at" { hasAddedAt = true }
        }
        if !hasAddedAt {
            try execute(
                "ALTER TABLE comics ADD COLUMN added_at REAL NOT NULL DEFAULT 0",
                name: "迁移离线漫画加入时间"
            )
        }
        try execute(
            "UPDATE comics SET added_at = updated_at WHERE added_at <= 0",
            name: "回填离线漫画加入时间"
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS idx_comics_added_at ON comics(added_at DESC, id)",
            name: "创建离线漫画加入时间索引"
        )
    }

    private func ensureComicCoverRelativePathColumn() throws {
        var hasCoverRelativePath = false
        try query("PRAGMA table_info(comics)", name: "检查离线封面路径") { row in
            if text(row, 1) == "cover_relative_path" { hasCoverRelativePath = true }
        }
        if !hasCoverRelativePath {
            try execute(
                "ALTER TABLE comics ADD COLUMN cover_relative_path TEXT",
                name: "迁移离线封面路径"
            )
        }
    }

    private func ensureFavoriteComicCoverRelativePathColumn() throws {
        var hasCoverRelativePath = false
        try query("PRAGMA table_info(favorite_comics)", name: "检查收藏封面路径") { row in
            if text(row, 1) == "cover_relative_path" { hasCoverRelativePath = true }
        }
        if !hasCoverRelativePath {
            try execute(
                "ALTER TABLE favorite_comics ADD COLUMN cover_relative_path TEXT",
                name: "迁移收藏封面路径"
            )
        }
    }

    /// Cover files are shared by the offline library and any number of
    /// account-scoped favorite rows. Reference checks run when a download is
    /// deleted or a corrupt file is invalidated, so index both nullable path
    /// columns instead of scanning thousands of favorite rows.
    private func ensureCoverReferenceIndexes() throws {
        try execute(
            """
            CREATE INDEX IF NOT EXISTS idx_comics_cover_relative_path
                ON comics(cover_relative_path)
                WHERE cover_relative_path IS NOT NULL;
            CREATE INDEX IF NOT EXISTS idx_favorite_comics_cover_relative_path
                ON favorite_comics(cover_relative_path)
                WHERE cover_relative_path IS NOT NULL;
            """,
            name: "创建封面引用索引"
        )
    }

    // MARK: - Favorite cache helpers

    private func validateAccountID(_ accountID: String) throws {
        let normalized = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw OfflineLibraryDatabaseError.invalidData("收藏缓存账户 ID 不能为空")
        }
        guard normalized == accountID else {
            throw OfflineLibraryDatabaseError.invalidData("收藏缓存账户 ID 不能包含首尾空白")
        }
    }

    private func replaceFavoriteFoldersUnlocked(
        accountID: String,
        folders: [FavoriteFolder]
    ) throws {
        var retainedIDs: Set<String> = []
        for (sort, folder) in folders.enumerated() {
            guard !folder.id.isEmpty else {
                throw OfflineLibraryDatabaseError.invalidData("收藏夹 ID 不能为空")
            }
            guard folder.count >= 0 else {
                throw OfflineLibraryDatabaseError.invalidData(
                    "收藏夹 \(folder.id) 的总数不能为负数"
                )
            }
            guard retainedIDs.insert(folder.id).inserted else { continue }
            try upsertFavoriteFolder(
                accountID: accountID,
                folderID: folder.id,
                name: folder.name,
                sort: sort,
                total: folder.count,
                // 上游 folder_list 通常不返回 count；0 不能覆盖已完成同步的本地总数。
                preserveExistingTotal: folder.id != "0" && folder.count == 0
            )
        }

        var obsoleteIDs: [String] = []
        let current = try prepare(
            "SELECT folder_id FROM favorite_folders WHERE account_id = ?",
            name: "对比收藏夹缓存"
        )
        defer { sqlite3_finalize(current) }
        try bind(accountID, to: 1, in: current, name: "对比收藏夹缓存")
        try consumeRows(current, name: "对比收藏夹缓存") { row in
            let folderID = text(row, 0)
            if !retainedIDs.contains(folderID) { obsoleteIDs.append(folderID) }
        }

        for folderID in obsoleteIDs {
            let delete = try prepare(
                "DELETE FROM favorite_folders WHERE account_id = ? AND folder_id = ?",
                name: "删除过期收藏夹缓存"
            )
            defer { sqlite3_finalize(delete) }
            try bind(accountID, to: 1, in: delete, name: "删除过期收藏夹缓存")
            try bind(folderID, to: 2, in: delete, name: "删除过期收藏夹缓存")
            try stepDone(delete, name: "删除过期收藏夹缓存")
        }
        try cleanupOrphanFavoriteComics(accountID: accountID)
    }

    private func upsertFavoriteFolder(
        accountID: String,
        folderID: String,
        name: String,
        sort: Int,
        total: Int,
        preserveExistingTotal: Bool = false
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO favorite_folders
                (account_id, folder_id, name, sort, total, last_synced_at)
            VALUES (?, ?, ?, ?, ?, 0)
            ON CONFLICT(account_id, folder_id) DO UPDATE SET
                name = excluded.name,
                sort = excluded.sort,
                total = CASE WHEN ? = 1 THEN favorite_folders.total ELSE excluded.total END
            """,
            name: "保存收藏夹缓存"
        )
        defer { sqlite3_finalize(statement) }
        try bind(accountID, to: 1, in: statement, name: "保存收藏夹缓存")
        try bind(folderID, to: 2, in: statement, name: "保存收藏夹缓存")
        try bind(name.isEmpty ? (folderID == "0" ? "全部收藏" : folderID) : name, to: 3, in: statement, name: "保存收藏夹缓存")
        try bind(sort, to: 4, in: statement, name: "保存收藏夹缓存")
        try bind(total, to: 5, in: statement, name: "保存收藏夹缓存")
        try bind(preserveExistingTotal ? 1 : 0, to: 6, in: statement, name: "保存收藏夹缓存")
        try stepDone(statement, name: "保存收藏夹缓存")
    }

    private func ensureFavoriteFolder(
        accountID: String,
        folderID: String,
        total: Int
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO favorite_folders
                (account_id, folder_id, name, sort, total, last_synced_at)
            VALUES (?, ?, ?, 0, ?, 0)
            ON CONFLICT(account_id, folder_id) DO NOTHING
            """,
            name: "确保收藏夹缓存存在"
        )
        defer { sqlite3_finalize(statement) }
        try bind(accountID, to: 1, in: statement, name: "确保收藏夹缓存存在")
        try bind(folderID, to: 2, in: statement, name: "确保收藏夹缓存存在")
        try bind(folderID == "0" ? "全部收藏" : folderID, to: 3, in: statement, name: "确保收藏夹缓存存在")
        try bind(total, to: 4, in: statement, name: "确保收藏夹缓存存在")
        try stepDone(statement, name: "确保收藏夹缓存存在")
    }

    private func updateFavoriteFolderTotal(
        accountID: String,
        folderID: String,
        total: Int
    ) throws {
        let statement = try prepare(
            """
            UPDATE favorite_folders SET total = ?
            WHERE account_id = ? AND folder_id = ?
            """,
            name: "更新收藏夹总数"
        )
        defer { sqlite3_finalize(statement) }
        try bind(total, to: 1, in: statement, name: "更新收藏夹总数")
        try bind(accountID, to: 2, in: statement, name: "更新收藏夹总数")
        try bind(folderID, to: 3, in: statement, name: "更新收藏夹总数")
        try stepDone(statement, name: "更新收藏夹总数")
    }

    private func upsertFavoriteComic(
        accountID: String,
        comic: ComicSummary,
        updatedAt: Date
    ) throws {
        guard !comic.id.isEmpty else {
            throw OfflineLibraryDatabaseError.invalidData("收藏漫画 ID 不能为空")
        }
        let statement = try prepare(
            """
            INSERT INTO favorite_comics (account_id, comic_id, name, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(account_id, comic_id) DO UPDATE SET
                name = excluded.name,
                updated_at = excluded.updated_at
            """,
            name: "保存收藏漫画缓存"
        )
        defer { sqlite3_finalize(statement) }
        try bind(accountID, to: 1, in: statement, name: "保存收藏漫画缓存")
        try bind(comic.id, to: 2, in: statement, name: "保存收藏漫画缓存")
        try bind(comic.name, to: 3, in: statement, name: "保存收藏漫画缓存")
        try bind(updatedAt.timeIntervalSince1970, to: 4, in: statement, name: "保存收藏漫画缓存")
        try stepDone(statement, name: "保存收藏漫画缓存")

        try replaceFavoriteNames(
            accountID: accountID,
            comicID: comic.id,
            values: comic.authors,
            table: "favorite_comic_authors",
            operationName: "保存收藏作者缓存"
        )
        try replaceFavoriteNames(
            accountID: accountID,
            comicID: comic.id,
            values: comic.tags,
            table: "favorite_comic_tags",
            operationName: "保存收藏标签缓存"
        )
    }

    private func replaceFavoriteNames(
        accountID: String,
        comicID: String,
        values: [String],
        table: String,
        operationName: String
    ) throws {
        let delete = try prepare(
            "DELETE FROM \(table) WHERE account_id = ? AND comic_id = ?",
            name: operationName
        )
        defer { sqlite3_finalize(delete) }
        try bind(accountID, to: 1, in: delete, name: operationName)
        try bind(comicID, to: 2, in: delete, name: operationName)
        try stepDone(delete, name: operationName)

        for (position, name) in values.enumerated() {
            let insert = try prepare(
                "INSERT INTO \(table) (account_id, comic_id, position, name) VALUES (?, ?, ?, ?)",
                name: operationName
            )
            defer { sqlite3_finalize(insert) }
            try bind(accountID, to: 1, in: insert, name: operationName)
            try bind(comicID, to: 2, in: insert, name: operationName)
            try bind(position, to: 3, in: insert, name: operationName)
            try bind(name, to: 4, in: insert, name: operationName)
            try stepDone(insert, name: operationName)
        }
    }

    /// Caller must hold `lock`; when used by a writer it must also be inside the
    /// same transaction as the subsequent insert.
    private func existingFavoriteComicIDsUnlocked(
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder,
        comicIDs: [String]
    ) throws -> Set<String> {
        guard !comicIDs.isEmpty else { return [] }

        // Leave ample room below SQLite builds that use the traditional 999
        // variable limit: each query also binds account_id and folder_id.
        let chunkSize = 500
        var result: Set<String> = []
        result.reserveCapacity(comicIDs.count)

        var start = 0
        while start < comicIDs.count {
            let end = min(start + chunkSize, comicIDs.count)
            let chunk = comicIDs[start..<end]
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let statement = try prepare(
                """
                SELECT comic_id
                FROM favorite_memberships
                WHERE account_id = ? AND folder_id = ? AND order_mode = ?
                  AND comic_id IN (\(placeholders))
                """,
                name: "查询已存在收藏"
            )
            defer { sqlite3_finalize(statement) }
            try bind(accountID, to: 1, in: statement, name: "查询已存在收藏")
            try bind(folderID, to: 2, in: statement, name: "查询已存在收藏")
            try bind(sortOrder.rawValue, to: 3, in: statement, name: "查询已存在收藏")
            for (offset, comicID) in chunk.enumerated() {
                try bind(
                    comicID,
                    to: Int32(offset + 4),
                    in: statement,
                    name: "查询已存在收藏"
                )
            }
            try consumeRows(statement, name: "查询已存在收藏") { row in
                result.insert(text(row, 0))
            }
            start = end
        }
        return result
    }

    private func favoriteMembershipCountUnlocked(
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder
    ) throws -> Int {
        let statement = try prepare(
            """
            SELECT COUNT(*)
            FROM favorite_memberships
            WHERE account_id = ? AND folder_id = ? AND order_mode = ?
            """,
            name: "统计收藏夹本地数量"
        )
        defer { sqlite3_finalize(statement) }
        try bind(accountID, to: 1, in: statement, name: "统计收藏夹本地数量")
        try bind(folderID, to: 2, in: statement, name: "统计收藏夹本地数量")
        try bind(sortOrder.rawValue, to: 3, in: statement, name: "统计收藏夹本地数量")
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw currentError(name: "统计收藏夹本地数量")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func favoriteFolderTotal(accountID: String, folderID: String) throws -> Int {
        let statement = try prepare(
            "SELECT total FROM favorite_folders WHERE account_id = ? AND folder_id = ?",
            name: "读取收藏夹总数"
        )
        defer { sqlite3_finalize(statement) }
        try bind(accountID, to: 1, in: statement, name: "读取收藏夹总数")
        try bind(folderID, to: 2, in: statement, name: "读取收藏夹总数")
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return Int(sqlite3_column_int64(statement, 0))
        case SQLITE_DONE:
            return 0
        default:
            throw currentError(name: "读取收藏夹总数")
        }
    }

    private func cachedFavoriteNames(
        table: String,
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder,
        offset: Int,
        limit: Int,
        operationName: String
    ) throws -> [String: [String]] {
        var values: [String: [String]] = [:]
        let statement = try prepare(
            """
            SELECT n.comic_id, n.name
            FROM \(table) n
            JOIN (
                SELECT comic_id, position
                FROM favorite_memberships
                WHERE account_id = ? AND folder_id = ? AND order_mode = ?
                ORDER BY position, comic_id
                LIMIT ? OFFSET ?
            ) selected ON selected.comic_id = n.comic_id
            WHERE n.account_id = ?
            ORDER BY selected.position, n.position
            """,
            name: operationName
        )
        defer { sqlite3_finalize(statement) }
        try bind(accountID, to: 1, in: statement, name: operationName)
        try bind(folderID, to: 2, in: statement, name: operationName)
        try bind(sortOrder.rawValue, to: 3, in: statement, name: operationName)
        try bind(limit, to: 4, in: statement, name: operationName)
        try bind(offset, to: 5, in: statement, name: operationName)
        try bind(accountID, to: 6, in: statement, name: operationName)
        try consumeRows(statement, name: operationName) { row in
            values[text(row, 0), default: []].append(text(row, 1))
        }
        return values
    }

    private func favoriteSyncItemCount(
        accountID: String,
        folderID: String,
        sortOrder: FavoriteComicSortOrder,
        syncToken: String
    ) throws -> Int {
        let statement = try prepare(
            """
            SELECT COUNT(DISTINCT comic_id)
            FROM favorite_memberships
            WHERE account_id = ? AND folder_id = ? AND order_mode = ?
              AND sync_token = ?
            """,
            name: "验证收藏同步完整性"
        )
        defer { sqlite3_finalize(statement) }
        try bind(accountID, to: 1, in: statement, name: "验证收藏同步完整性")
        try bind(folderID, to: 2, in: statement, name: "验证收藏同步完整性")
        try bind(sortOrder.rawValue, to: 3, in: statement, name: "验证收藏同步完整性")
        try bind(syncToken, to: 4, in: statement, name: "验证收藏同步完整性")
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw currentError(name: "验证收藏同步完整性")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func cleanupOrphanFavoriteComics(accountID: String) throws {
        let statement = try prepare(
            """
            DELETE FROM favorite_comics
            WHERE account_id = ?
              AND NOT EXISTS (
                  SELECT 1 FROM favorite_memberships m
                  WHERE m.account_id = favorite_comics.account_id
                    AND m.comic_id = favorite_comics.comic_id
              )
            """,
            name: "清理孤立收藏漫画缓存"
        )
        defer { sqlite3_finalize(statement) }
        try bind(accountID, to: 1, in: statement, name: "清理孤立收藏漫画缓存")
        try stepDone(statement, name: "清理孤立收藏漫画缓存")
    }

    // MARK: - Writes

    private func upsertComicUnlocked(
        _ comic: ComicSummary,
        storageDirectoryName: String,
        updatedAt: Date
    ) throws {
        guard !comic.id.isEmpty else {
            throw OfflineLibraryDatabaseError.invalidData("漫画 ID 不能为空")
        }
        guard !storageDirectoryName.isEmpty else {
            throw OfflineLibraryDatabaseError.invalidData("漫画 \(comic.id) 的下载目录名不能为空")
        }

        let statement = try prepare(
            """
            INSERT INTO comics (id, name, storage_directory_name, added_at, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                storage_directory_name = excluded.storage_directory_name,
                updated_at = excluded.updated_at
            """,
            name: "保存离线漫画"
        )
        defer { sqlite3_finalize(statement) }
        try bind(comic.id, to: 1, in: statement, name: "保存离线漫画")
        try bind(comic.name, to: 2, in: statement, name: "保存离线漫画")
        try bind(storageDirectoryName, to: 3, in: statement, name: "保存离线漫画")
        try bind(updatedAt.timeIntervalSince1970, to: 4, in: statement, name: "保存离线漫画")
        try bind(updatedAt.timeIntervalSince1970, to: 5, in: statement, name: "保存离线漫画")
        try stepDone(statement, name: "保存离线漫画")

        try replaceNames(
            comic.authors,
            comicID: comic.id,
            dictionaryTable: "authors",
            junctionTable: "comic_authors",
            foreignKey: "author_id",
            operationName: "保存作者"
        )
        try replaceNames(
            comic.tags,
            comicID: comic.id,
            dictionaryTable: "tags",
            junctionTable: "comic_tags",
            foreignKey: "tag_id",
            operationName: "保存标签"
        )
    }

    private func replaceNames(
        _ values: [String],
        comicID: String,
        dictionaryTable: String,
        junctionTable: String,
        foreignKey: String,
        operationName: String
    ) throws {
        // Table identifiers are fixed internal constants supplied only above.
        let delete = try prepare(
            "DELETE FROM \(junctionTable) WHERE comic_id = ?",
            name: operationName
        )
        defer { sqlite3_finalize(delete) }
        try bind(comicID, to: 1, in: delete, name: operationName)
        try stepDone(delete, name: operationName)

        var seen: Set<String> = []
        for (position, rawValue) in values.enumerated() {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { continue }

            let dictionary = try prepare(
                "INSERT INTO \(dictionaryTable) (name) VALUES (?) ON CONFLICT(name) DO NOTHING",
                name: operationName
            )
            try bind(value, to: 1, in: dictionary, name: operationName)
            do {
                try stepDone(dictionary, name: operationName)
                sqlite3_finalize(dictionary)
            } catch {
                sqlite3_finalize(dictionary)
                throw error
            }

            let junction = try prepare(
                """
                INSERT INTO \(junctionTable) (comic_id, \(foreignKey), position)
                SELECT ?, id, ? FROM \(dictionaryTable) WHERE name = ?
                """,
                name: operationName
            )
            try bind(comicID, to: 1, in: junction, name: operationName)
            try bind(position, to: 2, in: junction, name: operationName)
            try bind(value, to: 3, in: junction, name: operationName)
            do {
                try stepDone(junction, name: operationName)
                sqlite3_finalize(junction)
            } catch {
                sqlite3_finalize(junction)
                throw error
            }
        }

        try execute(
            "DELETE FROM \(dictionaryTable) WHERE NOT EXISTS (SELECT 1 FROM \(junctionTable) WHERE \(foreignKey) = \(dictionaryTable).id)",
            name: operationName
        )
    }

    private func upsertChapterUnlocked(
        comicID: String,
        chapter: Chapter,
        expectedPageCount: Int
    ) throws {
        guard !comicID.isEmpty, !chapter.id.isEmpty else {
            throw OfflineLibraryDatabaseError.invalidData("漫画 ID 和章节 ID 不能为空")
        }
        guard expectedPageCount >= 0 else {
            throw OfflineLibraryDatabaseError.invalidData("预期页数不能为负数: \(expectedPageCount)")
        }
        let statement = try prepare(
            """
            INSERT INTO chapters (id, comic_id, title, sort, expected_page_count)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                comic_id = excluded.comic_id,
                title = excluded.title,
                sort = excluded.sort,
                expected_page_count = excluded.expected_page_count
            """,
            name: "保存离线章节"
        )
        defer { sqlite3_finalize(statement) }
        try bind(chapter.id, to: 1, in: statement, name: "保存离线章节")
        try bind(comicID, to: 2, in: statement, name: "保存离线章节")
        try bind(chapter.title, to: 3, in: statement, name: "保存离线章节")
        try bind(chapter.sort, to: 4, in: statement, name: "保存离线章节")
        try bind(expectedPageCount, to: 5, in: statement, name: "保存离线章节")
        try stepDone(statement, name: "保存离线章节")
    }

    private func writePage(
        chapterID: String,
        pageIndex: Int,
        globalOrdinal: Int,
        relativePath: String,
        completed: Bool,
        preserveMatchingCompletion: Bool
    ) throws {
        let completedUpdate = preserveMatchingCompletion
            ? "CASE WHEN pages.completed = 1 AND pages.relative_path = excluded.relative_path THEN 1 ELSE 0 END"
            : "excluded.completed"
        let statement = try prepare(
            """
            INSERT INTO pages (chapter_id, page_index, global_ordinal, relative_path, completed)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(chapter_id, page_index) DO UPDATE SET
                global_ordinal = excluded.global_ordinal,
                relative_path = excluded.relative_path,
                completed = \(completedUpdate)
            """,
            name: completed ? "保存已完成页" : "预留下载页"
        )
        defer { sqlite3_finalize(statement) }
        let operation = completed ? "保存已完成页" : "预留下载页"
        try bind(chapterID, to: 1, in: statement, name: operation)
        try bind(pageIndex, to: 2, in: statement, name: operation)
        try bind(globalOrdinal, to: 3, in: statement, name: operation)
        try bind(relativePath, to: 4, in: statement, name: operation)
        try bind(completed ? 1 : 0, to: 5, in: statement, name: operation)
        try stepDone(statement, name: operation)
    }

    private func touchComic(forChapterID chapterID: String) throws {
        let statement = try prepare(
            """
            UPDATE comics SET updated_at = ?
            WHERE id = (SELECT comic_id FROM chapters WHERE id = ?)
            """,
            name: "更新离线漫画时间"
        )
        defer { sqlite3_finalize(statement) }
        try bind(Date.now.timeIntervalSince1970, to: 1, in: statement, name: "更新离线漫画时间")
        try bind(chapterID, to: 2, in: statement, name: "更新离线漫画时间")
        try stepDone(statement, name: "更新离线漫画时间")
    }

    private func validatePageValues(pageIndex: Int, globalOrdinal: Int, relativePath: String) throws {
        guard pageIndex >= 0 else {
            throw OfflineLibraryDatabaseError.invalidData("页索引不能为负数: \(pageIndex)")
        }
        guard globalOrdinal > 0 else {
            throw OfflineLibraryDatabaseError.invalidData("图片全局编号必须大于 0: \(globalOrdinal)")
        }
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
            throw OfflineLibraryDatabaseError.invalidData("页路径必须是非空相对路径: \(relativePath)")
        }
    }

    private func nextGlobalOrdinalUnlocked(comicID: String) throws -> Int {
        let statement = try prepare(
            """
            SELECT COALESCE(MAX(p.global_ordinal), 0) + 1
            FROM pages p JOIN chapters c ON c.id = p.chapter_id
            WHERE c.comic_id = ?
            """,
            name: "计算迁移图片编号"
        )
        defer { sqlite3_finalize(statement) }
        try bind(comicID, to: 1, in: statement, name: "计算迁移图片编号")
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw currentError(name: "计算迁移图片编号")
        }
        return max(1, Int(sqlite3_column_int64(statement, 0)))
    }

    // MARK: - SQLite primitives

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func transaction<T>(
        begin: String = "BEGIN IMMEDIATE",
        _ body: () throws -> T
    ) throws -> T {
        try execute(begin, name: "开始数据库事务")
        do {
            let result = try body()
            try execute("COMMIT", name: "提交数据库事务")
            return result
        } catch {
            try? execute("ROLLBACK", name: "回滚数据库事务")
            throw error
        }
    }

    private func handle() throws -> OpaquePointer {
        guard let database else {
            throw OfflineLibraryDatabaseError.invalidData("数据库已关闭")
        }
        return database
    }

    private func execute(_ sql: String, name: String) throws {
        let database = try handle()
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            if let errorPointer { sqlite3_free(errorPointer) }
            throw OfflineLibraryDatabaseError.operation(name: name, code: result, message: message)
        }
    }

    private func prepare(_ sql: String, name: String) throws -> OpaquePointer {
        let database = try handle()
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw OfflineLibraryDatabaseError.operation(
                name: name,
                code: result,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        return statement
    }

    private func query(
        _ sql: String,
        name: String,
        row: (OpaquePointer) throws -> Void
    ) throws {
        let statement = try prepare(sql, name: name)
        defer { sqlite3_finalize(statement) }
        try consumeRows(statement, name: name, row: row)
    }

    /// Called only while this database's lock is already held. The history
    /// schema is owned by a second connection and may be initialized later, so
    /// shared-cover operations must tolerate either connection opening first.
    private func tableHasColumn(_ table: String, column: String) throws -> Bool {
        guard ["reading_history"].contains(table) else { return false }
        let statement = try prepare(
            "PRAGMA table_info(\(table))",
            name: "检查共享封面引用表"
        )
        defer { sqlite3_finalize(statement) }
        var found = false
        try consumeRows(statement, name: "检查共享封面引用表") { row in
            if text(row, 1) == column { found = true }
        }
        return found
    }

    private func consumeRows(
        _ statement: OpaquePointer,
        name: String,
        row: (OpaquePointer) throws -> Void
    ) throws {
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                try row(statement)
            case SQLITE_DONE:
                return
            default:
                throw currentError(name: name)
            }
        }
    }

    private func stepDone(_ statement: OpaquePointer, name: String) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw currentError(name: name, code: result)
        }
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer, name: String) throws {
        let result = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, Self.sqliteTransient)
        }
        guard result == SQLITE_OK else { throw currentError(name: name, code: result) }
    }

    private func bind(_ value: Int, to index: Int32, in statement: OpaquePointer, name: String) throws {
        let result = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
        guard result == SQLITE_OK else { throw currentError(name: name, code: result) }
    }

    private func bind(_ value: Double, to index: Int32, in statement: OpaquePointer, name: String) throws {
        let result = sqlite3_bind_double(statement, index, value)
        guard result == SQLITE_OK else { throw currentError(name: name, code: result) }
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

    private func pageRecord(from statement: OpaquePointer) -> OfflinePageRecord {
        OfflinePageRecord(
            chapterID: text(statement, 0),
            pageIndex: Int(sqlite3_column_int64(statement, 1)),
            globalOrdinal: Int(sqlite3_column_int64(statement, 2)),
            relativePath: text(statement, 3),
            completed: sqlite3_column_int(statement, 4) != 0
        )
    }

    private func currentError(name: String, code: Int32? = nil) -> OfflineLibraryDatabaseError {
        guard let database else {
            return .invalidData("数据库已关闭")
        }
        return .operation(
            name: name,
            code: code ?? sqlite3_errcode(database),
            message: String(cString: sqlite3_errmsg(database))
        )
    }
}
