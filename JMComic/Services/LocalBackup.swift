import Foundation

struct BackupChapter: Codable, Equatable {
    var id: String
    var title: String
    var sort: Int
    var expectedPages: Int
}
struct BackupBook: Codable, Equatable, Identifiable {
    var comic: ComicSummary
    var chapters: [BackupChapter]
    var updatedAt: Date
    var id: String { comic.id }
    init(_ item: OfflineComic) {
        comic = item.comic; updatedAt = item.updatedAt
        chapters = item.chapters.map { BackupChapter(id: $0.id, title: $0.title, sort: $0.sort, expectedPages: $0.expectedPageCount) }
    }
}
enum BackupValue: Codable, Equatable {
    case bool(Bool), integer(Int), text(String)
    var object: Any { switch self { case .bool(let v): v; case .integer(let v): v; case .text(let v): v } }
}
struct LocalBackup: Codable {
    var schemaVersion = 1
    var createdAt = Date()
    var progress: ChapterProgressRecords
    var settings: [String: BackupValue]
    var blockedTags: [String]
    var books: [BackupBook]
    static let maximumBytes = 12 * 1_024 * 1_024
    static let maximumProgress = 50_000
    static let integerRanges: [String: ClosedRange<Int>] = [
        PageImagePreferences.prefetchCountKey: 0...6,
        DownloadConcurrencyPreferences.cachedImageRequestsKey: 1...5,
        DownloadConcurrencyPreferences.simultaneousComicsKey: 1...5,
        DownloadConcurrencyPreferences.pageDownloadsPerComicKey: 1...5
    ]
    static let boolKeys = [InterfacePreferences.showExplanatoryTextKey, PageImagePreferences.repairChromaKey]
    static let textOptions: [String: Set<String>] = [
        "jm.appearance.palette": Set(["ivory", "lightGray", "lightGreen", "lightPink", "paleYellow", "deepGray"]),
        "jm.appearance.color-mode": Set(["system", "light", "dark"]),
        PageImagePreferences.storageKey: Set(["lossless", "spaceSavingJPEG"]),
        "downloads.librarySort": Set(["加入先后", "收藏夹", "名称"])
    ]
    static func settings(defaults: UserDefaults) -> [String: BackupValue] {
        var output: [String: BackupValue] = [:]
        for key in boolKeys where defaults.object(forKey: key) != nil { output[key] = .bool(defaults.bool(forKey: key)) }
        for (key, range) in integerRanges where defaults.object(forKey: key) != nil {
            output[key] = .integer(min(range.upperBound, max(range.lowerBound, defaults.integer(forKey: key))))
        }
        for (key, options) in textOptions {
            if let text = defaults.string(forKey: key), options.contains(text) { output[key] = .text(text) }
        }
        return output
    }
    func validate(now: Date = .now) throws {
        func require(_ condition: Bool) throws { if !condition { throw ManagementError.invalidBackup } }
        func validText(_ value: String, limit: Int = 1024) -> Bool { !value.isEmpty && value.utf8.count <= limit && !value.contains("\0") }
        func validDate(_ value: Date) -> Bool { value.timeIntervalSince1970.isFinite && value.timeIntervalSince1970 >= 0 && value <= now.addingTimeInterval(300) }
        try require(schemaVersion == 1 && validDate(createdAt))
        try require(books.count <= 5000 && progress.count <= 5000 && blockedTags.count <= 200 && settings.count <= 16)
        try require(progress.values.reduce(0) { $0 + $1.count } <= Self.maximumProgress)
        for (comic, records) in progress {
            try require(validText(comic, limit: 128))
            for (chapter, record) in records {
                try require(validText(chapter, limit: 128) && record.chapterID == chapter && (0...1_000_000).contains(record.pageIndex) && validDate(record.updatedAt))
            }
        }
        for tag in blockedTags { try require(validText(tag, limit: 256) && !BlockedTagsStore.normalize(tag).isEmpty) }
        var ids = Set<String>(), chapters = 0
        for book in books {
            try require(validText(book.id, limit: 128) && ids.insert(book.id).inserted && validText(book.comic.name) && validDate(book.updatedAt))
            try require(book.comic.authors.count <= 100 && book.comic.tags.count <= 200)
            for text in book.comic.authors + book.comic.tags { try require(validText(text, limit: 256)) }
            chapters += book.chapters.count
            var seen = Set<String>()
            for chapter in book.chapters {
                try require(validText(chapter.id, limit: 128) && seen.insert(chapter.id).inserted && validText(chapter.title)
                    && (0...1_000_000).contains(chapter.sort) && (0...100_000).contains(chapter.expectedPages))
            }
        }
        try require(chapters <= 50_000)
        for (key, value) in settings {
            switch value {
            case .bool: try require(Self.boolKeys.contains(key))
            case .integer(let value): try require(Self.integerRanges[key]?.contains(value) == true)
            case .text(let value): try require(Self.textOptions[key]?.contains(value) == true)
            }
        }
    }
    static func read(_ url: URL) throws -> Self {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= maximumBytes else { throw ManagementError.invalidBackup }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw ManagementError.invalidBackup }
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate()
        return result
    }
    static func mergeBooks(_ incoming: [BackupBook], into existing: [BackupBook]) -> [BackupBook] {
        var records = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for book in incoming {
            if let old = records[book.id] {
                var merged = book.updatedAt > old.updatedAt ? book : old
                // Never drop chapters absent from an incomplete backup.
                var chapters = Dictionary(uniqueKeysWithValues: old.chapters.map { ($0.id, $0) })
                for chapter in book.chapters where chapters[chapter.id] == nil || book.updatedAt > old.updatedAt { chapters[chapter.id] = chapter }
                merged.chapters = chapters.values.sorted { ($0.sort, $0.id) < ($1.sort, $1.id) }
                records[book.id] = merged
            } else { records[book.id] = book }
        }
        return records.values.sorted { $0.id < $1.id }
    }
}

enum ManagementError: LocalizedError {
    case invalidBackup, missingPages(Int), changedFile, tooLarge, busy
    var errorDescription: String? {
        switch self {
        case .invalidBackup: "备份格式、版本、记录数量或字段无效；未修改本地数据"
        case .missingPages(let count): "有 \(count) 页缺失或索引不完整，不能完整导出"
        case .changedFile: "导出期间文件已被修改或删除，请重试"
        case .tooLarge: "内容超过此轻量导出的大小或数量上限"
        case .busy: "操作正在进行，请稍后重试"
        }
    }
}

/// One atomic receipt is the durable import boundary. It contains no paths,
/// credentials or completed download rows. A crash after publication replays
/// only the safe merge, once, on next launch.
actor BackupReceiptStore {
    struct Receipt: Codable { let id: UUID; var backup: LocalBackup }
    let url: URL
    init(url: URL) { self.url = url }
    func load() throws -> Receipt? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= LocalBackup.maximumBytes else { throw ManagementError.invalidBackup }
        let receipt = try JSONDecoder().decode(Receipt.self, from: data)
        try receipt.backup.validate()
        return receipt
    }
    func publish(_ backup: LocalBackup) throws -> Receipt {
        try backup.validate()
        var merged = backup
        merged.books = LocalBackup.mergeBooks(backup.books, into: try load()?.backup.books ?? [])
        try merged.validate()
        let receipt = Receipt(id: UUID(), backup: merged)
        let data = try JSONEncoder().encode(receipt)
        guard data.count <= LocalBackup.maximumBytes else { throw ManagementError.tooLarge }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic) // no state changes before success
        return receipt
    }
}

@MainActor
final class BackupCoordinator: ObservableObject {
    static let shared = BackupCoordinator()
    @Published private(set) var restoredBooks: [BackupBook] = []
    @Published private(set) var busy = false
    @Published private(set) var recoveryError: String?
    private let store: BackupReceiptStore
    private let defaults: UserDefaults
    private let appliedKey = "jm.backup.applied-receipt"
    init(defaults: UserDefaults = .standard, receiptURL: URL? = nil) {
        self.defaults = defaults
        store = BackupReceiptStore(url: receiptURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("database/restore-receipt.json"))
    }
    func recoverOnLaunch(progress: ReadingProgressStore, blocked: BlockedTagsStore) async {
        do { try await recover(progress: progress, blocked: blocked); recoveryError = nil }
        catch { recoveryError = error.localizedDescription }
    }
    func recover(progress: ReadingProgressStore, blocked: BlockedTagsStore) async throws {
        guard !busy else { return }
        busy = true; defer { busy = false }
        if let receipt = try await store.load() { await apply(receipt, progress: progress, blocked: blocked) }
    }
    func merge(_ backup: LocalBackup, progress: ReadingProgressStore, blocked: BlockedTagsStore) async throws {
        guard !busy else { throw ManagementError.busy }
        busy = true; defer { busy = false }
        let union = Set((blocked.tags + backup.blockedTags).map(BlockedTagsStore.normalize))
        guard union.count <= 200 else { throw ManagementError.tooLarge }
        let receipt = try await store.publish(backup)
        await apply(receipt, progress: progress, blocked: blocked)
    }
    private func apply(_ receipt: BackupReceiptStore.Receipt, progress: ReadingProgressStore, blocked: BlockedTagsStore) async {
        restoredBooks = receipt.backup.books
        guard defaults.string(forKey: appliedKey) != receipt.id.uuidString else { return }
        // Existing explicit settings have no reliable per-key timestamp, so
        // preserve them. Progress has timestamps and merges per chapter.
        for (key, value) in receipt.backup.settings where defaults.object(forKey: key) == nil { defaults.set(value.object, forKey: key) }
        blocked.mergePreservingExisting(receipt.backup.blockedTags)
        await progress.merge(receipt.backup.progress)
        defaults.set(receipt.id.uuidString, forKey: appliedKey)
    }
}
