import Foundation

struct ChapterDownloadProgress: Identifiable, Hashable {
    enum State: String, Hashable {
        case preparing = "正在准备"
        case downloading = "下载中"
        case paused = "已暂停"
        case finished = "已完成"
        case failed = "失败"
    }

    let id: String
    var comicID: String
    var comicName: String
    var chapterID: String
    var chapterTitle: String
    var completedPages: Int
    var totalPages: Int
    var state: State
    var error: String?

    var fraction: Double {
        totalPages == 0 ? 0 : Double(completedPages) / Double(totalPages)
    }
}

/// Keeps global pause/resume semantics explicit and testable. Terminal tasks
/// are never restarted by a global control; a failed chapter still requires
/// the existing explicit retry path, and a finished chapter stays finished.
enum DownloadGlobalControlPolicy {
    static func pausing(_ state: ChapterDownloadProgress.State) -> ChapterDownloadProgress.State {
        switch state {
        case .preparing, .downloading:
            return .paused
        case .paused, .finished, .failed:
            return state
        }
    }

    static func resuming(
        _ state: ChapterDownloadProgress.State,
        totalPages: Int
    ) -> ChapterDownloadProgress.State {
        guard state == .paused else { return state }
        return totalPages == 0 ? .preparing : .downloading
    }

    static func canPause(_ progress: [ChapterDownloadProgress], globallyPaused: Bool) -> Bool {
        guard !globallyPaused else { return false }
        return progress.contains { $0.state == .preparing || $0.state == .downloading }
    }
}

struct PageDownloadDescriptor: Codable {
    var comic: ComicSummary
    var chapterID: String
    var chapterTitle: String
    var chapterSort: Int
    var scrambleID: Int
    var filename: String
    var pageIndex: Int
    var globalOrdinal: Int
    var totalPages: Int
    var relativePath: String
    var imageDomains: [String]
    var domainIndex: Int
    var referer: String
    // nil 用于兼容旧版任务描述。新版不恢复系统后台任务。
    var attemptID: String?
    // Captured at enqueue, then copied unchanged by retry/pause/resume.
    // Optional only for decoding legacy descriptors; no background restore.
    var imageProcessing: PageImageProcessing? = nil
    var imageStorage: PageImageStorage? = nil

    var progressID: String { "\(comic.id):\(chapterID)" }
    var attemptToken: String { attemptID ?? "legacy:\(progressID)" }

    func storing(_ image: ImageScrambler.EncodedPage) -> Self {
        var result = self
        let path = relativePath as NSString
        let suffix = "." + image.fileExtension
        let stem = (path.lastPathComponent as NSString).deletingPathExtension
        let name = DownloadStorageNaming.safeComponent(
            stem, maxUTF8Bytes: DownloadStorageNaming.filesystemComponentByteLimit - suffix.utf8.count
        ) + suffix
        result.relativePath = (path.deletingLastPathComponent as NSString).appendingPathComponent(name)
        return result
    }
}

enum DownloadConcurrencyPreferences {
    static let cachedImageRequestsKey = "downloads.cachedImageConcurrency"
    static let simultaneousComicsKey = "downloads.simultaneousComicConcurrency"
    static let pageDownloadsPerComicKey = "downloads.pageConcurrencyPerComic"
    static let allowedRange = 1...5

    static let defaultCachedImageRequests = 4
    static let defaultSimultaneousComics = 2
    static let defaultPageDownloadsPerComic = 3

    static func bounded(_ value: Int) -> Int {
        min(allowedRange.upperBound, max(allowedRange.lowerBound, value))
    }

    static func value(
        forKey key: String,
        default defaultValue: Int,
        defaults: UserDefaults = .standard
    ) -> Int {
        guard defaults.object(forKey: key) != nil else { return bounded(defaultValue) }
        return bounded(defaults.integer(forKey: key))
    }

    static func cachedImageRequests(defaults: UserDefaults = .standard) -> Int {
        value(forKey: cachedImageRequestsKey, default: defaultCachedImageRequests, defaults: defaults)
    }

    static func simultaneousComics(defaults: UserDefaults = .standard) -> Int {
        value(forKey: simultaneousComicsKey, default: defaultSimultaneousComics, defaults: defaults)
    }

    static func pageDownloadsPerComic(defaults: UserDefaults = .standard) -> Int {
        value(forKey: pageDownloadsPerComicKey, default: defaultPageDownloadsPerComic, defaults: defaults)
    }
}

/// Enforces both the distinct-comic limit and each comic's page-transfer limit.
/// A permit represents a real running URLSession data task, not a UI counter.
actor DownloadTransferLimiter {
    private struct Waiter {
        let token: String
        let comicID: String
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var activeTokens: [String: String] = [:]
    private var activePagesByComic: [String: Int] = [:]
    private var waiters: [Waiter] = []
    private var comicLimit = DownloadConcurrencyPreferences.defaultSimultaneousComics
    private var pageLimit = DownloadConcurrencyPreferences.defaultPageDownloadsPerComic

    /// Returns false for a duplicate token. Treating a duplicate as a granted
    /// permit would let a second URLSessionTask run without being counted.
    @discardableResult
    func acquire(token: String, comicID: String, comicLimit: Int, pageLimit: Int) async -> Bool {
        self.comicLimit = DownloadConcurrencyPreferences.bounded(comicLimit)
        self.pageLimit = DownloadConcurrencyPreferences.bounded(pageLimit)
        guard activeTokens[token] == nil,
              !waiters.contains(where: { $0.token == token }) else { return false }
        if canStart(comicID: comicID) {
            return start(token: token, comicID: comicID)
        }
        return await withCheckedContinuation { continuation in
            waiters.append(Waiter(token: token, comicID: comicID, continuation: continuation))
        }
    }

    func release(token: String) {
        guard let comicID = activeTokens.removeValue(forKey: token) else { return }
        let remaining = max(0, (activePagesByComic[comicID] ?? 1) - 1)
        if remaining == 0 { activePagesByComic.removeValue(forKey: comicID) }
        else { activePagesByComic[comicID] = remaining }
        drain()
    }

    func snapshot() -> (activeComics: Int, maximumPagesForOneComic: Int) {
        (activePagesByComic.count, activePagesByComic.values.max() ?? 0)
    }

    private func canStart(comicID: String) -> Bool {
        let pages = activePagesByComic[comicID] ?? 0
        guard pages < pageLimit else { return false }
        return pages > 0 || activePagesByComic.count < comicLimit
    }

    @discardableResult
    private func start(token: String, comicID: String) -> Bool {
        guard activeTokens[token] == nil else { return false }
        activeTokens[token] = comicID
        activePagesByComic[comicID, default: 0] += 1
        return true
    }

    private func drain() {
        var index = 0
        while index < waiters.count {
            let waiter = waiters[index]
            if canStart(comicID: waiter.comicID) {
                waiters.remove(at: index)
                let didStart = start(token: waiter.token, comicID: waiter.comicID)
                waiter.continuation.resume(returning: didStart)
                index = 0
            } else {
                index += 1
            }
        }
    }
}

/// Serializes one logical chapter download without tying correctness to
/// URLSession callback order. A token remains current through CDN retries, but
/// a callback from a superseded token can never mutate or retry the new run.
final class DownloadAttemptRegistry {
    private let lock = NSLock()
    private var currentTokens: [String: String] = [:]

    func beginIfIdle(progressID: String, token: String = UUID().uuidString) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard currentTokens[progressID] == nil else { return nil }
        currentTokens[progressID] = token
        return token
    }

    @discardableResult
    func adoptIfIdle(progressID: String, token: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let current = currentTokens[progressID] { return current == token }
        currentTokens[progressID] = token
        return true
    }

    func isCurrent(progressID: String, token: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentTokens[progressID] == token
    }

    @discardableResult
    func finishIfCurrent(progressID: String, token: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard currentTokens[progressID] == token else { return false }
        currentTokens.removeValue(forKey: progressID)
        return true
    }

    func invalidateComic(_ comicID: String) {
        let prefix = "\(comicID):"
        lock.lock()
        currentTokens = currentTokens.filter { !$0.key.hasPrefix(prefix) }
        lock.unlock()
    }
}

enum DownloadFailurePolicy {
    static func isCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isCancellation(underlying)
        }
        return false
    }

}

/// Coordinates a filesystem move with its SQLite index update. Filesystems and
/// SQLite cannot share a transaction, so the file moves first and is moved back
/// if the index commit fails. The original mapping therefore remains usable.
enum DownloadPathMigration {
    static func moveCompletedFileThenCommit(
        source: URL,
        destination: URL,
        createDestinationDirectory: () throws -> Void,
        commitIndex: (_ remainsCompleted: Bool) throws -> Void
    ) throws -> Bool {
        let fileManager = FileManager.default
        let sourceExists = fileManager.fileExists(atPath: source.path)
        let destinationExisted = fileManager.fileExists(atPath: destination.path)
        var movedSource = false

        if sourceExists, source != destination, !destinationExisted {
            try createDestinationDirectory()
            try fileManager.moveItem(at: source, to: destination)
            movedSource = true
        }

        let remainsCompleted = fileManager.fileExists(atPath: destination.path)
        do {
            try commitIndex(remainsCompleted)
        } catch {
            if movedSource {
                do {
                    try fileManager.moveItem(at: destination, to: source)
                } catch let rollbackError {
                    throw DownloadStorageError.migrationRollback(
                        from: source,
                        to: destination,
                        indexError: error as NSError,
                        rollbackError: rollbackError as NSError
                    )
                }
            }
            throw error
        }

        // If both copies predated the repair, keep the indexed destination and
        // remove the now-unowned source only after SQLite committed successfully.
        if remainsCompleted, sourceExists, !movedSource, source != destination {
            try? fileManager.removeItem(at: source)
        }
        return remainsCompleted
    }
}

enum DownloadStorageMigration {
    static let layoutVersionKey = "downloads.storageLayoutVersion"
    static let currentLayoutVersion = 2

    /// Moves indexed build-1…7 files from Documents/<comic>/<page> into
    /// Documents/download/<comic>/<chapter>/<page> and updates SQLite after
    /// each durable move. Re-running is safe after any intermediate failure.
    static func migrateIndexedLibrary(
        database: OfflineLibraryDatabase,
        documentsRoot: URL,
        downloadRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: downloadRoot, withIntermediateDirectories: true)
        for comic in try database.loadLibrary() {
            let duplicatedTitles = Dictionary(grouping: comic.chapters) {
                DownloadStorageNaming.chapterFolderName(chapterTitle: $0.title)
            }.filter { $0.value.count > 1 }.keys
            for chapter in comic.chapters {
                let baseChapterDirectory = DownloadStorageNaming.chapterFolderName(chapterTitle: chapter.title)
                let chapterDirectory = duplicatedTitles.contains(baseChapterDirectory)
                    ? DownloadStorageNaming.disambiguatedChapterFolderName(
                        chapterTitle: chapter.title,
                        chapterID: chapter.id
                    )
                    : baseChapterDirectory
                for record in try database.pageRecords(comicID: comic.id, chapterID: chapter.id) {
                    let currentComponents = record.relativePath.split(separator: "/").map(String.init)
                    let existingFileName = currentComponents.last ?? ""
                    let fileName = DownloadStorageNaming.isSafeComponent(existingFileName)
                        ? existingFileName
                        : DownloadStorageNaming.pageFileName(
                            comicName: comic.comic.name,
                            imageNumber: record.globalOrdinal,
                            fileExtension: (record.relativePath as NSString).pathExtension
                        )
                    let newRelativePath = "\(comic.storageDirectoryName)/\(chapterDirectory)/\(fileName)"
                    let destination = downloadRoot.appendingPathComponent(newRelativePath)
                    if record.relativePath == newRelativePath,
                       !record.completed || fileManager.fileExists(atPath: destination.path) {
                        // The layout version marker prevents future full scans;
                        // this fast path also keeps an interrupted retry cheap.
                        // A completed row whose file still lives under the old
                        // Documents root must fall through and be moved even
                        // when its relative path already has three components.
                        continue
                    }
                    let currentInDownload = downloadRoot.appendingPathComponent(record.relativePath)
                    let currentInDocuments = documentsRoot.appendingPathComponent(record.relativePath)
                    let source: URL
                    if fileManager.fileExists(atPath: currentInDownload.path) {
                        source = currentInDownload
                    } else if fileManager.fileExists(atPath: currentInDocuments.path) {
                        source = currentInDocuments
                    } else {
                        // Let the transactional helper distinguish an existing
                        // destination from a genuinely missing completed file.
                        source = currentInDocuments
                    }

                    if record.completed {
                        _ = try DownloadPathMigration.moveCompletedFileThenCommit(
                            source: source,
                            destination: destination,
                            createDestinationDirectory: {
                                try fileManager.createDirectory(
                                    at: destination.deletingLastPathComponent(),
                                    withIntermediateDirectories: true
                                )
                            },
                            commitIndex: { remainsCompleted in
                                if remainsCompleted {
                                    try database.upsertPage(
                                        chapterID: chapter.id,
                                        pageIndex: record.pageIndex,
                                        globalOrdinal: record.globalOrdinal,
                                        relativePath: newRelativePath
                                    )
                                } else {
                                    try database.reservePage(
                                        chapterID: chapter.id,
                                        pageIndex: record.pageIndex,
                                        globalOrdinal: record.globalOrdinal,
                                        relativePath: newRelativePath
                                    )
                                }
                            }
                        )
                    } else if record.relativePath != newRelativePath {
                        try database.reservePage(
                            chapterID: chapter.id,
                            pageIndex: record.pageIndex,
                            globalOrdinal: record.globalOrdinal,
                            relativePath: newRelativePath
                        )
                    }

                    removeEmptyAncestors(
                        startingAt: source.deletingLastPathComponent(),
                        stoppingBefore: source.path.hasPrefix(downloadRoot.path) ? downloadRoot : documentsRoot,
                        fileManager: fileManager
                    )
                }
            }
        }
    }

    private static func removeEmptyAncestors(
        startingAt directory: URL,
        stoppingBefore root: URL,
        fileManager: FileManager
    ) {
        var candidate = directory
        while candidate != root, candidate.path.hasPrefix(root.path + "/") {
            let entries = (try? fileManager.contentsOfDirectory(atPath: candidate.path)) ?? []
            guard entries.isEmpty else { return }
            try? fileManager.removeItem(at: candidate)
            candidate.deleteLastPathComponent()
        }
    }
}

/// Names written into the user-visible Documents directory must obey the
/// filesystem's byte limit, not merely Swift's `Character` count. A Japanese
/// or Chinese title can require three UTF-8 bytes per character, so truncating
/// to 100/120 characters can still exceed iOS' 255-byte NAME_MAX and make every
/// page fail with the unhelpful "Cannot create file" error.
enum DownloadStorageNaming {
    /// Leave a little headroom below NAME_MAX for filesystem normalization.
    static let generatedComponentByteLimit = 240
    static let filesystemComponentByteLimit = 255

    static func folderName(for comic: ComicSummary) -> String {
        let rawAuthor = comic.authors.isEmpty ? "未知作者" : comic.authors.joined(separator: "、")
        let author = safeComponent(rawAuthor, maxUTF8Bytes: 72)
        let suffix = "-\(author)"
        let titleBudget = max(1, generatedComponentByteLimit - suffix.utf8.count)
        let title = safeComponent(comic.name, maxUTF8Bytes: titleBudget)
        return title + suffix
    }

    static func disambiguatedFolderName(_ preferred: String, comicID: String) -> String {
        let safeID = safeComponent(comicID, maxUTF8Bytes: 40)
        let suffix = " (JM\(safeID))"
        let baseBudget = max(1, generatedComponentByteLimit - suffix.utf8.count)
        return safeComponent(preferred, maxUTF8Bytes: baseBudget) + suffix
    }

    static func pageFileName(comicName: String, imageNumber: Int, fileExtension: String = "jpg") -> String {
        let supported = ["jpg", "jpeg", "png", "webp", "gif", "bmp", "tiff", "heic", "heif"]
        let ext = supported.contains(fileExtension.lowercased()) ? fileExtension.lowercased() : "jpg"
        let suffix = "-\(max(1, imageNumber)).\(ext)"
        let titleBudget = max(1, generatedComponentByteLimit - suffix.utf8.count)
        return safeComponent(comicName, maxUTF8Bytes: titleBudget) + suffix
    }

    static func chapterFolderName(chapterTitle: String) -> String {
        safeComponent(chapterTitle, maxUTF8Bytes: 160)
    }

    static func disambiguatedChapterFolderName(chapterTitle: String, chapterID: String) -> String {
        let suffix = " (JM\(safeComponent(chapterID, maxUTF8Bytes: 36)))"
        let titleBudget = max(1, generatedComponentByteLimit - suffix.utf8.count)
        return safeComponent(chapterTitle, maxUTF8Bytes: titleBudget) + suffix
    }

    static func relativePath(
        comicName: String,
        storageDirectoryName: String,
        chapterDirectoryName: String,
        imageNumber: Int,
        fileExtension: String = "jpg"
    ) -> String {
        "\(storageDirectoryName)/\(chapterDirectoryName)/\(pageFileName(comicName: comicName, imageNumber: imageNumber, fileExtension: fileExtension))"
    }

    static func safeComponent(_ value: String, maxUTF8Bytes: Int) -> String {
        let byteLimit = max(1, min(maxUTF8Bytes, filesystemComponentByteLimit))
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
            .union(.controlCharacters)
        let normalized = value.precomposedStringWithCanonicalMapping

        var cleaned = ""
        var previousWasReplacement = false
        for character in normalized {
            let shouldReplace = character.unicodeScalars.contains { forbidden.contains($0) }
            if shouldReplace {
                if !previousWasReplacement { cleaned.append("_") }
                previousWasReplacement = true
            } else {
                cleaned.append(character)
                previousWasReplacement = false
            }
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: ".")
        ))
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { cleaned = "未命名" }

        var result = ""
        var usedBytes = 0
        for character in cleaned {
            let text = String(character)
            let bytes = text.utf8.count
            guard usedBytes + bytes <= byteLimit else { break }
            result.append(character)
            usedBytes += bytes
        }
        result = result.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: ".")
        ))
        if result.isEmpty {
            return byteLimit >= "未命名".utf8.count ? "未命名" : "_"
        }
        return result
    }

    static func isSafeComponent(_ value: String) -> Bool {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              value.utf8.count <= filesystemComponentByteLimit else { return false }
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
            .union(.controlCharacters)
        return !value.unicodeScalars.contains { forbidden.contains($0) }
    }

    static func isSafeRelativePagePath(
        _ value: String,
        directoryName: String,
        chapterDirectoryName: String
    ) -> Bool {
        let components = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count == 3,
              components[0] == directoryName,
              components[1] == chapterDirectoryName,
              components.allSatisfy(isSafeComponent) else { return false }
        return true
    }
}

enum DownloadStorageError: LocalizedError {
    case createDirectory(URL, NSError)
    case writeFile(URL, NSError)
    case migrateFile(from: URL, to: URL, underlying: NSError)
    case migrationRollback(from: URL, to: URL, indexError: NSError, rollbackError: NSError)

    var errorDescription: String? {
        switch self {
        case let .createDirectory(url, error):
            return "无法创建漫画目录“\(url.lastPathComponent)”：\(Self.detail(error))"
        case let .writeFile(url, error):
            return "无法保存图片“\(url.lastPathComponent)”：\(Self.detail(error))"
        case let .migrateFile(source, destination, error):
            return "无法修复旧下载路径“\(source.lastPathComponent)”→“\(destination.lastPathComponent)”：\(Self.detail(error))"
        case let .migrationRollback(source, destination, indexError, rollbackError):
            return "旧下载路径索引更新失败，且文件回滚失败“\(destination.lastPathComponent)”→“\(source.lastPathComponent)”："
                + "\(Self.detail(indexError)) / 回滚：\(Self.detail(rollbackError))"
        }
    }

    private static func detail(_ error: NSError) -> String {
        var values = ["\(error.localizedDescription) [\(error.domain) \(error.code)]"]
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            values.append("\(underlying.localizedDescription) [\(underlying.domain) \(underlying.code)]")
        }
        return values.joined(separator: " / ")
    }
}

/// Mutable UI state is changed on the main actor/main queue; task registries,
/// tombstones and scheduling controls use their own locks/actor. URLSession's
/// sendable callbacks therefore safely share this long-lived coordinator.
final class DownloadManager: NSObject, ObservableObject, @unchecked Sendable {
    private struct CoverCacheWork {
        let token: UUID
        let task: Task<URL?, Never>
    }

    /// Per-page database commits stay immediate, while this small trailing
    /// buffer keeps a burst of concurrent page completions from invalidating
    /// every SwiftUI observer once per page.
    private struct PendingProgressPublish {
        let completedPages: Int
        let totalPages: Int
        let attemptToken: String
    }

    static let shared = DownloadManager()
    @Published private(set) var progress: [ChapterDownloadProgress] = []
    @Published private(set) var library: [OfflineComic] = []
    @Published private(set) var downloadsArePaused = false
    @Published private(set) var deletingComicIDs: Set<String> = []

    private let tombstoneLock = NSLock()
    private var tombstones: Set<String> = []
    private let terminalFailureLock = NSLock()
    private var terminallyFailedProgressIDs: Set<String> = []
    private let attemptRegistry = DownloadAttemptRegistry()
    private let transferLimiter = DownloadTransferLimiter()
    private let globalControlLock = NSLock()
    private var globalPauseRequested = false
    private var globalControlGeneration: UInt = 0
    /// Pages that had not yet created a URLSession task when global pause was
    /// requested. Every entry still owns its limiter permit. Resume therefore
    /// starts it directly instead of releasing/reacquiring the same token, which
    /// also closes the rapid pause -> resume race around the limiter actor.
    private var globallyDeferredDescriptors: [String: PageDownloadDescriptor] = [:]
    private let fileCommits = OfflineFileCommitQueue()
    private let decodeWorkLock = NSLock()
    private var decodeWorks: [String: (id: UUID, comicID: String, progressID: String, task: Task<Void, Never>)] = [:]
    private var documentsRootOverride: URL?
    private let coverCacheLock = NSLock()
    private var coverCacheWorks: [String: CoverCacheWork] = [:]
    private var pendingProgressPublishes: [String: PendingProgressPublish] = [:]
    private var progressPublishTasks: [String: Task<Void, Never>] = [:]
    private var libraryReloadTask: Task<Void, Never>?
    private var libraryReloadRevision: UInt = 0
    private var libraryReloadCompletions: [(Result<[OfflineComic], Error>) -> Void] = []
    private var database: OfflineLibraryDatabase?
    /// A normal data-task session is the only download transport. It avoids the
    /// nsurlsessiond temporary-file failures seen in sideloaded builds.
    private lazy var foregroundSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.allowsCellularAccess = true
        configuration.httpMaximumConnectionsPerHost = DownloadConcurrencyPreferences.allowedRange.upperBound
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 90
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private override init() {
        super.init()
        // 下载索引、收藏缓存与阅读历史共用 Documents/database/JMComic.db。
        database = JMComicDatabase.shared
        migrateLegacyStorageIfNeeded()
        migrateIndexedStorageLayoutIfNeeded()
        library = loadLibrary()
    }

    /// Isolated storage for synthetic regression fixtures; production still
    /// uses the shared database and existing migration/bootstrap entry point.
    init(database: OfflineLibraryDatabase, documentsRoot: URL) {
        self.database = database
        self.documentsRootOverride = documentsRoot
        super.init()
        library = loadLibrary()
    }


    var canPauseAllDownloads: Bool {
        DownloadGlobalControlPolicy.canPause(progress, globallyPaused: downloadsArePaused)
    }

    var canResumeAllDownloads: Bool { downloadsArePaused }

    /// Suspends existing data tasks and closes the scheduling gate before any
    /// later page can start. Tasks currently waiting for a limiter permit move
    /// into `globallyDeferredDescriptors` when their permit becomes available.
    @MainActor
    func pauseAllDownloads() {
        globalControlLock.lock()
        globalPauseRequested = true
        globalControlGeneration &+= 1
        let generation = globalControlGeneration
        globalControlLock.unlock()

        downloadsArePaused = true
        var updatedProgress = progress
        for index in updatedProgress.indices {
            updatedProgress[index].state = DownloadGlobalControlPolicy.pausing(updatedProgress[index].state)
        }
        progress = updatedProgress
        foregroundSession.getAllTasks { [weak self] tasks in
            self?.applySessionControl(
                tasks: tasks,
                paused: true,
                generation: generation
            )
        }
    }

    /// Opens the gate, resumes already-created URLSession tasks, then sends
    /// deferred pages through the normal limiter again. Failed and completed
    /// chapters are deliberately untouched.
    @MainActor
    func resumeAllDownloads() {
        globalControlLock.lock()
        globalPauseRequested = false
        globalControlGeneration &+= 1
        let generation = globalControlGeneration
        let deferred = Array(globallyDeferredDescriptors.values)
        globallyDeferredDescriptors.removeAll(keepingCapacity: true)
        globalControlLock.unlock()

        downloadsArePaused = false
        var updatedProgress = progress
        for index in updatedProgress.indices {
            updatedProgress[index].state = DownloadGlobalControlPolicy.resuming(
                updatedProgress[index].state,
                totalPages: updatedProgress[index].totalPages
            )
        }
        progress = updatedProgress
        foregroundSession.getAllTasks { [weak self] tasks in
            self?.applySessionControl(
                tasks: tasks,
                paused: false,
                generation: generation
            )
        }
        for descriptor in deferred { startForegroundTransfer(descriptor) }
    }

    @MainActor
    func enqueue(comic: ComicSummary, chapters: [Chapter], api: APIClient) async throws {
        guard let database else { throw OfflineLibraryDatabaseError.invalidData("数据库未初始化") }
        guard !deletingComicIDs.contains(comic.id) else {
            throw OfflineLibraryDatabaseError.invalidData("该离线漫画正在删除，请稍后重试")
        }
        let imageProcessing = PageImagePreferences.processing()
        let imageStorage = PageImagePreferences.storage()
        setTombstoned(false, comicID: comic.id)
        let storageDirectoryName = try resolvedStorageDirectoryName(for: comic)
        try database.upsertComic(comic, storageDirectoryName: storageDirectoryName)
        // Cover persistence is independent from page transfers. Starting it
        // here guarantees a newly downloaded comic gains a visible local cover
        // without delaying chapter metadata or the first image task.
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.ensureCoverCached(for: comic, api: api)
        }
        if let comicIndex = library.firstIndex(where: { $0.id == comic.id }) {
            library[comicIndex].storageDirectoryName = storageDirectoryName
        }
        var seenChapterIDs: Set<String> = []
        for chapter in chapters.sorted(by: { $0.sort < $1.sort }) {
            guard seenChapterIDs.insert(chapter.id).inserted else { continue }
            let progressID = "\(comic.id):\(chapter.id)"
            // Mark the attempt before the first await. A second tap/re-entrant
            // enqueue observes it immediately and cannot create another task set.
            guard let attemptID = attemptRegistry.beginIfIdle(progressID: progressID) else {
                continue
            }
            setTerminallyFailed(false, progressID: progressID)
            upsertProgress(ChapterDownloadProgress(
                id: progressID,
                comicID: comic.id,
                comicName: comic.name,
                chapterID: chapter.id,
                chapterTitle: chapter.title,
                completedPages: 0,
                totalPages: 0,
                state: isGlobalPauseRequested ? .paused : .preparing
            ))
            do {
                let detail = try await api.chapter(id: chapter.id)
                // chapter_view_template applies the selected app_img_shunt and
                // promotes its returned `imghost`; capture domains only after
                // that request so downloads use the chosen route too.
                let imageDomains = api.configuration.imageDomains
                guard !imageDomains.isEmpty else { throw APIError.noAvailableDomain }
                let referer = api.configuration.apiDomains.first ?? ""
                let prepared = try await fileCommits.run { [self] in
                    guard attemptRegistry.isCurrent(progressID: progressID, token: attemptID),
                          !isTombstoned(comicID: comic.id) else { throw CancellationError() }
                    try database.upsertChapter(
                        comicID: comic.id,
                        chapter: chapter,
                        expectedPageCount: detail.images.count
                    )
                    // Resolve once per chapter. Loading the whole SQLite library for
                    // every image used to make large chapters pause before starting.
                    let chapterDirectoryName = visibleChapterDirectoryName(
                        for: chapter,
                        comicID: comic.id
                    )
                    let originalRecords = try database.pageRecords(comicID: comic.id, chapterID: chapter.id)
                    var records = originalRecords
                    records = try repairUnsafeReservedPaths(
                        records,
                        comic: comic,
                        storageDirectoryName: storageDirectoryName,
                        chapterDirectoryName: chapterDirectoryName,
                        database: database
                    )
                    var didMutateVisibleLibrary = records != originalRecords
                    for record in records where record.completed {
                        let url = offlineRoot.appendingPathComponent(record.relativePath)
                        if !FileManager.default.fileExists(atPath: url.path) {
                            try database.deletePage(chapterID: chapter.id, pageIndex: record.pageIndex)
                            didMutateVisibleLibrary = true
                        }
                    }
                    records = try database.pageRecords(comicID: comic.id, chapterID: chapter.id)
                    let recordsByPage = Dictionary(uniqueKeysWithValues: records.map { ($0.pageIndex, $0) })
                    let alreadyDownloaded = records.filter { record in
                        record.completed && FileManager.default.fileExists(
                            atPath: offlineRoot.appendingPathComponent(record.relativePath).path
                        )
                    }.count
                    // Reserve the ordinal range on the same serial queue as final
                    // writes/deletion; a retry cannot race an older page commit.
                    var nextGlobalOrdinal = try database.nextGlobalOrdinal(comicID: comic.id)
                    var descriptors: [PageDownloadDescriptor] = []
                    for (index, filename) in detail.images.enumerated() {
                        let relativePath: String
                        let globalOrdinal: Int
                        if let record = recordsByPage[index] {
                            relativePath = record.relativePath
                            globalOrdinal = record.globalOrdinal
                            if record.completed,
                               FileManager.default.fileExists(atPath: offlineRoot.appendingPathComponent(relativePath).path) {
                                continue
                            }
                        } else {
                            var candidate = visibleRelativePath(
                                for: comic,
                                storageDirectoryName: storageDirectoryName,
                                chapterDirectoryName: chapterDirectoryName,
                                imageNumber: nextGlobalOrdinal
                            )
                            while FileManager.default.fileExists(atPath: offlineRoot.appendingPathComponent(candidate).path) {
                                nextGlobalOrdinal += 1
                                candidate = visibleRelativePath(
                                    for: comic,
                                    storageDirectoryName: storageDirectoryName,
                                    chapterDirectoryName: chapterDirectoryName,
                                    imageNumber: nextGlobalOrdinal
                                )
                            }
                            relativePath = candidate
                            globalOrdinal = nextGlobalOrdinal
                            try database.reservePage(
                                chapterID: chapter.id,
                                pageIndex: index,
                                globalOrdinal: globalOrdinal,
                                relativePath: relativePath
                            )
                            nextGlobalOrdinal += 1
                        }
                        let fileURL = offlineRoot.appendingPathComponent(relativePath)
                        // 这里的路径已经由数据库预留，覆盖的只可能是本页自己的未完成文件。
                        if FileManager.default.fileExists(atPath: fileURL.path) {
                            try? FileManager.default.removeItem(at: fileURL)
                        }
                        let descriptor = PageDownloadDescriptor(
                            comic: comic,
                            chapterID: chapter.id,
                            chapterTitle: chapter.title,
                            chapterSort: chapter.sort,
                            scrambleID: detail.scrambleID,
                            filename: filename,
                            pageIndex: index,
                            globalOrdinal: globalOrdinal,
                            totalPages: detail.images.count,
                            relativePath: relativePath,
                            imageDomains: imageDomains,
                            domainIndex: 0,
                            referer: referer,
                            attemptID: attemptID,
                            imageProcessing: imageProcessing,
                            imageStorage: imageStorage
                        )
                        descriptors.append(descriptor)
                    }
                    return (descriptors, alreadyDownloaded, didMutateVisibleLibrary ? loadLibrary() : nil)
                }
                guard attemptRegistry.isCurrent(progressID: progressID, token: attemptID),
                      !isTombstoned(comicID: comic.id) else { throw CancellationError() }
                if let refreshed = prepared.2 { library = refreshed }
                updateProgress(id: progressID) {
                    $0.completedPages = prepared.1
                    $0.totalPages = detail.images.count
                    $0.state = prepared.1 >= detail.images.count ? .finished
                        : (self.isGlobalPauseRequested ? .paused : .downloading)
                }
                var scheduledPageCount = 0
                for descriptor in prepared.0 {
                    if schedule(descriptor) { scheduledPageCount += 1 }
                }
                if scheduledPageCount == 0 {
                    attemptRegistry.finishIfCurrent(progressID: progressID, token: attemptID)
                }
            } catch {
                // A deleted/replaced attempt must not recreate progress or
                // alter the new generation after its metadata request returns.
                guard attemptRegistry.isCurrent(progressID: progressID, token: attemptID),
                      !isTombstoned(comicID: comic.id) else { throw CancellationError() }
                // Earlier records in a multi-page legacy repair may already have
                // committed before a later record fails. Reload those valid
                // commits before presenting the error.
                library = loadLibrary()
                attemptRegistry.finishIfCurrent(progressID: progressID, token: attemptID)
                let pending = takePendingProgressPublish(id: progressID)
                updateProgress(id: "\(comic.id):\(chapter.id)") {
                    if pending?.attemptToken == attemptID {
                        $0.completedPages = max($0.completedPages, pending?.completedPages ?? 0)
                    }
                    $0.state = .failed
                    $0.error = error.localizedDescription
                }
                throw error
            }
        }
    }

    @MainActor
    func exportPlan(comicID: String, chapterID: String?) async throws -> OfflineExportPlan {
        guard let database, !deletingComicIDs.contains(comicID) else { throw ManagementError.busy }
        let root = JMComicStorageLayout.downloadRoot(documentsRoot: documentsRoot)
        let cancellation = ExportCancellation()
        return try await withTaskCancellationHandler {
            try await fileCommits.run {
                try cancellation.check()
                guard let comic = try database.loadLibrary().first(where: { $0.id == comicID }) else { throw ManagementError.missingPages(1) }
                return try OfflineExportPlan.make(comic: comic, records: database.allPageRecords(comicID: comicID), root: root, chapterID: chapterID, checkCancellation: cancellation.check)
            }
        } onCancel: { cancellation.cancel() }
    }

    @MainActor
    func localPageURLs(comicID: String, chapterID: String) async -> [URL] {
        guard let comic = library.first(where: { $0.id == comicID }),
              let chapter = comic.chapters.first(where: { $0.id == chapterID }),
              chapter.isComplete else { return [] }
        let root = JMComicStorageLayout.downloadRoot(documentsRoot: documentsRoot)
        let urls = chapter.relativePagePaths.map { root.appendingPathComponent($0) }
        guard urls.count == chapter.expectedPageCount else { return [] }
        return await Task.detached(priority: .userInitiated) {
            urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } ? urls : []
        }.value
    }

    func localCoverURL(for comic: OfflineComic) -> URL? {
        guard let relativePath = comic.coverRelativePath,
              let url = JMComicCoverCacheStorage.fileURL(
                relativePath: relativePath,
                documentsRoot: documentsRoot
              ),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Downloads or adopts exactly one persistent cover for an offline comic.
    /// Calls from both enqueue and lazy list rows share the same in-flight task.
    @MainActor
    func ensureCoverCached(for comic: ComicSummary, api: APIClient) async -> URL? {
        if let stored = library.first(where: { $0.id == comic.id }),
           let url = localCoverURL(for: stored) {
            if await Self.isDecodableCoverFile(at: url) {
                return url
            }
            await invalidateCachedCover(comicID: comic.id, expectedURL: url)
        }
        if let existing = coverCacheWork(for: comic.id) {
            return await existing.task.value
        }

        let token = UUID()
        let task = Task<URL?, Never> { @MainActor [weak self] in
            guard let self else { return nil }
            defer { self.finishCoverCacheWork(comicID: comic.id, token: token) }
            do {
                return try await self.performCoverCache(
                    for: comic,
                    api: api,
                    token: token
                )
            } catch {
                guard !APIClient.isCancellation(error) else { return nil }
                NSLog("[JMComic] Cover cache failed for %@: %@", comic.id, error.localizedDescription)
                return nil
            }
        }
        let installed = installCoverCacheWork(
            CoverCacheWork(token: token, task: task),
            comicID: comic.id
        )
        if installed.token != token { task.cancel() }
        return await installed.task.value
    }

    /// Removes only the cache file currently owned by this comic. A stale view
    /// can therefore repair a corrupt cover without being able to delete an
    /// arbitrary user-visible file or another comic's newer cache entry.
    @MainActor
    func invalidateCachedCover(comicID: String, expectedURL: URL) async {
        guard let database else { return }
        cancelCoverCacheWork(comicID: comicID)
        let documents = documentsRoot
        let expected = expectedURL.standardizedFileURL
        let removed = (try? await fileCommits.run { () -> Bool in
            let indexedPath = try database.comicCoverRelativePath(comicID: comicID)
            let indexedURL = indexedPath.flatMap {
                JMComicCoverCacheStorage.fileURL(relativePath: $0, documentsRoot: documents)
            }?.standardizedFileURL
            let deterministicPath = JMComicCoverCacheStorage.relativePath(comicID: comicID)
            let deterministicURL = JMComicCoverCacheStorage.fileURL(relativePath: deterministicPath, documentsRoot: documents)?.standardizedFileURL
            guard expected == indexedURL || expected == deterministicURL else { return false }
            try database.clearCoverRelativePathReferences(indexedURL == expected ? indexedPath! : deterministicPath)
            if FileManager.default.fileExists(atPath: expected.path) { try FileManager.default.removeItem(at: expected) }
            return true
        }) == true
        if removed, let index = library.firstIndex(where: { $0.id == comicID }) {
            library[index].coverRelativePath = nil
        }
    }

    func favoriteFolderAssignments(
        accountID: String
    ) -> [String: OfflineFavoriteFolderAssignment] {
        guard let database else { return [:] }
        return (try? database.favoriteFolderAssignments(
            accountID: accountID,
            comicIDs: library.map(\.id)
        )) ?? [:]
    }

    @MainActor
    func delete(comicID: String) async throws {
        guard !deletingComicIDs.contains(comicID) else {
            throw OfflineLibraryDatabaseError.invalidData("该离线漫画正在删除")
        }
        guard let database else {
            throw OfflineLibraryDatabaseError.invalidData("数据库未初始化")
        }
        deletingComicIDs.insert(comicID)
        setTombstoned(true, comicID: comicID)
        cancelCoverCacheWork(comicID: comicID)
        attemptRegistry.invalidateComic(comicID)
        cancelDecodeWorks(comicID: comicID)
        let removedProgressIDs = Array(progress.lazy
            .filter { $0.comicID == comicID }
            .map(\.id))
        for progressID in removedProgressIDs {
            cancelPendingProgressPublish(id: progressID)
        }
        removeGloballyDeferredDescriptors { $0.comic.id == comicID }
        foregroundSession.getAllTasks { tasks in
            for task in tasks where self.descriptor(for: task)?.comic.id == comicID { task.cancel() }
        }

        let downloadRoot = JMComicStorageLayout.downloadRoot(documentsRoot: documentsRoot)
        let documentsRoot = documentsRoot
        do {
            let deleted = try await fileCommits.run {
                let fileManager = FileManager.default
                let indexedCoverPath = try database.comicCoverRelativePath(comicID: comicID)
                let records = try database.allPageRecords(comicID: comicID)
                let ownedFiles = records.map {
                    downloadRoot.appendingPathComponent($0.relativePath)
                }
                let chapterDirectories = Set(ownedFiles.map {
                    $0.deletingLastPathComponent()
                })

                for file in ownedFiles where fileManager.fileExists(atPath: file.path) {
                    try fileManager.removeItem(at: file)
                }
                for directory in chapterDirectories
                where fileManager.fileExists(atPath: directory.path) {
                    let remaining = try fileManager.contentsOfDirectory(atPath: directory.path)
                    if remaining.isEmpty { try fileManager.removeItem(at: directory) }
                }

                let comicDirectories = Set(chapterDirectories.map {
                    $0.deletingLastPathComponent()
                })
                for directory in comicDirectories
                where directory != downloadRoot && fileManager.fileExists(atPath: directory.path) {
                    let remaining = try fileManager.contentsOfDirectory(atPath: directory.path)
                    if remaining.isEmpty { try fileManager.removeItem(at: directory) }
                }

                let coverPaths = Set([
                    indexedCoverPath,
                    JMComicCoverCacheStorage.relativePath(comicID: comicID)
                ].compactMap { $0 })
                try database.deleteComic(comicID: comicID)
                for relativePath in coverPaths {
                    guard try !database.isCoverRelativePathReferenced(relativePath),
                          let coverURL = JMComicCoverCacheStorage.fileURL(
                            relativePath: relativePath,
                            documentsRoot: documentsRoot
                          ),
                          fileManager.fileExists(atPath: coverURL.path) else { continue }
                    try fileManager.removeItem(at: coverURL)
                }
                return (try database.loadLibrary(), ownedFiles)
            }

            LocalPageImages.shared.invalidate(urls: deleted.1)
            library = deleted.0
            progress.removeAll { $0.comicID == comicID }
            deletingComicIDs.remove(comicID)
        } catch {
            // The attempt tokens are already invalid, so clearing the
            // tombstone is safe and lets the user retry a partial deletion.
            setTombstoned(false, comicID: comicID)
            deletingComicIDs.remove(comicID)
            requestLibraryReload()
            throw error
        }
    }

    private var offlineRoot: URL {
        let root = JMComicStorageLayout.downloadRoot(documentsRoot: documentsRoot)
        if !FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ])
        }
        return root
    }

    private var documentsRoot: URL {
        if let documentsRootOverride { return documentsRootOverride }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var legacyRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JMComicOffline", isDirectory: true)
    }

    private func descriptor(for task: URLSessionTask) -> PageDownloadDescriptor? {
        guard let text = task.taskDescription,
              let data = Data(base64Encoded: text) else { return nil }
        return try? JSONDecoder().decode(PageDownloadDescriptor.self, from: data)
    }

    private func loadLibrary() -> [OfflineComic] {
        guard let database else { return [] }
        return (try? database.loadLibrary()) ?? []
    }

    @MainActor
    private func performCoverCache(for comic: ComicSummary, api: APIClient, token: UUID) async throws -> URL {
        guard isCurrentCoverCacheWork(comicID: comic.id, token: token),
              !isTombstoned(comicID: comic.id) else { throw CancellationError() }
        guard let database else { throw OfflineLibraryDatabaseError.invalidData("数据库未初始化") }
        let relativePath = JMComicCoverCacheStorage.relativePath(comicID: comic.id)
        guard let destination = JMComicCoverCacheStorage.fileURL(relativePath: relativePath, documentsRoot: documentsRoot)
        else { throw OfflineLibraryDatabaseError.invalidData("封面缓存路径无效") }
        var encoded: Data?
        if !(await Self.isDecodableCoverFile(at: destination)) {
            let image = try await api.displayImage(path: comic.coverPath)
            encoded = await Task.detached(priority: .utility) {
                image.jpegData(compressionQuality: 0.94)
            }.value
            guard encoded != nil else { throw OfflineLibraryDatabaseError.invalidData("封面无法编码为 JPEG") }
        }
        try Task.checkCancellation()
        let bytes = encoded
        // The guard, atomic file replacement and SQLite registration share the
        // same queue as deletion. Delete invalidates tokens first and then
        // queues removal, so an already-running commit is removed before a new
        // enqueue can begin; a later old commit fails its token check here.
        try await fileCommits.run { [self] in
            guard isCurrentCoverCacheWork(comicID: comic.id, token: token),
                  !isTombstoned(comicID: comic.id) else { throw CancellationError() }
            if let bytes { try writeVisibleImage(bytes, to: destination) }
            do {
                try database.setComicCoverRelativePath(comicID: comic.id, relativePath: relativePath)
            } catch {
                if (try? database.isCoverRelativePathReferenced(relativePath)) == false {
                    try? FileManager.default.removeItem(at: destination)
                }
                throw error
            }
        }
        guard isCurrentCoverCacheWork(comicID: comic.id, token: token),
              !isTombstoned(comicID: comic.id), !Task.isCancelled else { throw CancellationError() }
        if let index = library.firstIndex(where: { $0.id == comic.id }) { library[index].coverRelativePath = relativePath }
        return destination
    }

    nonisolated private static func isDecodableCoverFile(at url: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url),
                  APIClient.isLikelyImageData(data, contentType: nil),
                  (try? ImageScrambler.rasterImage(from: data)) != nil else {
                return false
            }
            return true
        }.value
    }

    private func coverCacheWork(for comicID: String) -> CoverCacheWork? {
        coverCacheLock.lock()
        defer { coverCacheLock.unlock() }
        return coverCacheWorks[comicID]
    }

    private func installCoverCacheWork(
        _ work: CoverCacheWork,
        comicID: String
    ) -> CoverCacheWork {
        coverCacheLock.lock()
        defer { coverCacheLock.unlock() }
        if let existing = coverCacheWorks[comicID] { return existing }
        coverCacheWorks[comicID] = work
        return work
    }

    private func isCurrentCoverCacheWork(comicID: String, token: UUID) -> Bool {
        coverCacheLock.lock()
        defer { coverCacheLock.unlock() }
        return coverCacheWorks[comicID]?.token == token
    }

    private func finishCoverCacheWork(comicID: String, token: UUID) {
        coverCacheLock.lock()
        defer { coverCacheLock.unlock() }
        if coverCacheWorks[comicID]?.token == token {
            coverCacheWorks[comicID] = nil
        }
    }

    private func cancelCoverCacheWork(comicID: String) {
        coverCacheLock.lock()
        let task = coverCacheWorks.removeValue(forKey: comicID)?.task
        coverCacheLock.unlock()
        task?.cancel()
    }

    private func recordCompleted(_ descriptor: PageDownloadDescriptor) {
        guard !isTombstoned(comicID: descriptor.comic.id),
              !isTerminallyFailed(progressID: descriptor.progressID),
              isCurrentAttempt(descriptor) else { return }
        do {
            guard let database else { throw OfflineLibraryDatabaseError.invalidData("数据库未初始化") }
            try database.upsertPage(
                chapterID: descriptor.chapterID,
                pageIndex: descriptor.pageIndex,
                globalOrdinal: descriptor.globalOrdinal,
                relativePath: descriptor.relativePath
            )
        } catch {
            failAttemptWithoutRetry(descriptor, error: error.localizedDescription)
            return
        }
        let completedPages = completedRecordCount(
            comicID: descriptor.comic.id,
            chapterID: descriptor.chapterID
        )
        let chapterIsComplete = completedPages >= descriptor.totalPages
        DispatchQueue.main.async {
            guard !self.isTombstoned(comicID: descriptor.comic.id),
                  self.isCurrentAttempt(descriptor) else { return }
            if chapterIsComplete {
                // Several ordinary data tasks may finish together. A DB reload
                // makes the first main-queue completion include every committed
                // path before it retires the shared attempt token.
                self.cancelPendingProgressPublish(id: descriptor.progressID)
                self.requestLibraryReload { result in
                    guard self.attemptRegistry.finishIfCurrent(
                        progressID: descriptor.progressID,
                        token: descriptor.attemptToken
                    ) else { return }
                    self.updateProgress(id: descriptor.progressID) {
                        $0.completedPages = $0.totalPages
                        switch result {
                        case .success:
                            $0.state = .finished
                            $0.error = nil
                        case let .failure(error):
                            $0.state = .failed
                            $0.error = "刷新离线索引失败：\(error.localizedDescription)"
                        }
                    }
                }
                return
            }
            // SQLite remains the source of truth for every completed page.
            // Do not rebuild/sort/publish the whole offline library until the
            // chapter is complete; only coalesce the lightweight task counter.
            self.scheduleProgressPublish(
                id: descriptor.progressID,
                completedPages: completedPages,
                totalPages: descriptor.totalPages,
                attemptToken: descriptor.attemptToken
            )
        }
    }

    @discardableResult
    private func schedule(_ descriptor: PageDownloadDescriptor) -> Bool {
        guard !isTombstoned(comicID: descriptor.comic.id),
              !isTerminallyFailed(progressID: descriptor.progressID),
              isCurrentAttempt(descriptor),
              descriptor.imageDomains.indices.contains(descriptor.domainIndex) else { return false }
        let token = transferToken(for: descriptor)
        let comicLimit = DownloadConcurrencyPreferences.simultaneousComics()
        let pageLimit = DownloadConcurrencyPreferences.pageDownloadsPerComic()
        Task { [weak self] in
            guard let self else { return }
            let acquired = await self.transferLimiter.acquire(
                token: token,
                comicID: descriptor.comic.id,
                comicLimit: comicLimit,
                pageLimit: pageLimit
            )
            guard acquired else { return }
            guard !self.isTombstoned(comicID: descriptor.comic.id),
                  !self.isTerminallyFailed(progressID: descriptor.progressID),
                  self.isCurrentAttempt(descriptor) else {
                await self.transferLimiter.release(token: token)
                return
            }
            self.startForegroundTransfer(descriptor)
        }
        return true
    }

    private func startForegroundTransfer(_ descriptor: PageDownloadDescriptor) {
        guard !isTombstoned(comicID: descriptor.comic.id),
              !isTerminallyFailed(progressID: descriptor.progressID),
              isCurrentAttempt(descriptor),
              descriptor.imageDomains.indices.contains(descriptor.domainIndex) else {
            finishTransfer(descriptor)
            return
        }
        let path = JMServiceProtocol.MediaPath.chapterPage(
            chapterID: descriptor.chapterID,
            filename: descriptor.filename
        )
        guard let url = URL(string: AppConfiguration.normalize(descriptor.imageDomains[descriptor.domainIndex]) + path) else {
            retryOrFail(descriptor, error: "图片线路地址无效")
            return
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 45
        )
        // One dead CDN must not hold an individual page indefinitely.
        request.setValue(
            JMServiceProtocol.Header.imageAccept,
            forHTTPHeaderField: JMServiceProtocol.Header.accept
        )
        request.setValue(
            JMServiceProtocol.Header.requestedWithValue,
            forHTTPHeaderField: JMServiceProtocol.Header.requestedWith
        )
        request.setValue(
            descriptor.referer,
            forHTTPHeaderField: JMServiceProtocol.Header.referer
        )
        // Hold the gate while the task is created and resumed. Therefore a
        // concurrent pause either sees this task in the session and suspends it,
        // or wins the lock and leaves only the descriptor queued; no page can
        // slip through between the pause flag and URLSession enumeration.
        globalControlLock.lock()
        guard !globalPauseRequested else {
            globallyDeferredDescriptors[transferToken(for: descriptor)] = descriptor
            globalControlLock.unlock()
            return
        }
        let task = foregroundSession.dataTask(with: request) { [weak self] data, response, error in
            self?.handleInMemoryDownload(
                descriptor,
                data: data,
                response: response,
                error: error
            )
        }
        if let data = try? JSONEncoder().encode(descriptor) {
            task.taskDescription = data.base64EncodedString()
        }
        task.resume()
        globalControlLock.unlock()
    }

    private func handleInMemoryDownload(
        _ descriptor: PageDownloadDescriptor,
        data: Data?,
        response: URLResponse?,
        error: Error?
    ) {
        guard !isTombstoned(comicID: descriptor.comic.id),
              !isTerminallyFailed(progressID: descriptor.progressID),
              isCurrentAttempt(descriptor) else {
            finishTransfer(descriptor)
            return
        }
        if let error {
            retryOrFail(
                descriptor,
                error: error.localizedDescription,
                underlyingError: error
            )
            return
        }
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            retryOrFail(
                descriptor,
                error: "图片下载失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）"
            )
            return
        }
        guard let data, !data.isEmpty else {
            retryOrFail(descriptor, error: "图片下载失败：服务器返回了空内容")
            return
        }
        guard APIClient.isLikelyImageData(
            data,
            contentType: httpResponse.value(
                forHTTPHeaderField: JMServiceProtocol.Header.contentType
            )
        ) else {
            retryOrFail(descriptor, error: "图片下载失败：CDN 返回的是 HTML/JSON 而不是图片")
            return
        }
        decodeAndStore(data, descriptor: descriptor)
    }

    private func decodeAndStore(_ encrypted: Data, descriptor: PageDownloadDescriptor) {
        let key = transferToken(for: descriptor)
        let id = UUID()
        decodeWorkLock.lock()
        let task = Task.detached(priority: .utility) { [self] in
            var transfersPermitToRetry = false
            defer {
                finishDecodeWork(key: key, id: id)
                if !transfersPermitToRetry { finishTransfer(descriptor) }
            }
            guard isCurrentAttempt(descriptor), !isTombstoned(comicID: descriptor.comic.id) else { return }
            do {
                _ = try await ReadingImageMemory.shared.decode(
                    data: encrypted, urgency: PageLoadUrgency(visible: false), bytesPerPixel: 20,
                    consume: { [self] decoded in try await storeDecodedPage(decoded, descriptor: descriptor) }
                ) {
                    try ImageScrambler.decode(encrypted, scrambleID: descriptor.scrambleID,
                        photoID: descriptor.chapterID, filename: descriptor.filename,
                        processing: descriptor.imageProcessing ?? .faithful, storage: descriptor.imageStorage ?? .lossless)
                }
            } catch {
                guard isCurrentAttempt(descriptor), !isTombstoned(comicID: descriptor.comic.id) else { return }
                if error is ReadingImageError || APIClient.isCancellation(error) {
                    failAttemptWithoutRetry(descriptor, error: error.localizedDescription)
                } else {
                    // Retry owns the transfer permit until its eventual completion.
                    transfersPermitToRetry = true
                    retryOrFail(descriptor, error: error.localizedDescription)
                }
            }
        }
        decodeWorks[key] = (id, descriptor.comic.id, descriptor.progressID, task)
        decodeWorkLock.unlock()
    }

    private func storeDecodedPage(_ decoded: ImageScrambler.EncodedPage, descriptor: PageDownloadDescriptor) async throws {
        try Task.checkCancellation()
        let stored = descriptor.storing(decoded)
        let destination = JMComicStorageLayout.downloadRoot(documentsRoot: documentsRoot).appendingPathComponent(stored.relativePath)
        do {
            try await fileCommits.run { [self] in
                guard isCurrentAttempt(descriptor), !isTombstoned(comicID: descriptor.comic.id),
                      !isTerminallyFailed(progressID: descriptor.progressID) else { throw CancellationError() }
                guard let database else { throw OfflineLibraryDatabaseError.invalidData("数据库未初始化") }
                if stored.relativePath != descriptor.relativePath {
                    guard !FileManager.default.fileExists(atPath: destination.path) else {
                        throw OfflineLibraryDatabaseError.invalidData("保存目标已存在：\(destination.lastPathComponent)")
                    }
                    try database.reservePage(chapterID: descriptor.chapterID, pageIndex: descriptor.pageIndex,
                        globalOrdinal: descriptor.globalOrdinal, relativePath: stored.relativePath)
                }
                try writeVisibleImage(decoded.data, to: destination)
                guard isCurrentAttempt(descriptor), !isTombstoned(comicID: descriptor.comic.id),
                      !isTerminallyFailed(progressID: descriptor.progressID) else {
                    try? FileManager.default.removeItem(at: destination)
                    throw CancellationError()
                }
                recordCompleted(stored)
            }
            await LocalPageImages.shared.invalidate(urls: [destination])
        } catch {
            if !APIClient.isCancellation(error) { failForLocalStorage(descriptor, destination: destination, error: error) }
        }
    }

    private func finishDecodeWork(key: String, id: UUID) {
        decodeWorkLock.lock()
        defer { decodeWorkLock.unlock() }
        if decodeWorks[key]?.id == id { decodeWorks[key] = nil }
    }

    private func cancelDecodeWorks(comicID: String? = nil, progressID: String? = nil) {
        decodeWorkLock.lock()
        let tasks = decodeWorks.values.filter { work in
            if let comicID { return work.comicID == comicID }
            return work.progressID == progressID
        }.map(\.task)
        decodeWorkLock.unlock()
        tasks.forEach { $0.cancel() }
    }

    private func retryOrFail(
        _ descriptor: PageDownloadDescriptor,
        error: String,
        underlyingError: Error? = nil
    ) {
        guard !isTombstoned(comicID: descriptor.comic.id),
              !isTerminallyFailed(progressID: descriptor.progressID),
              isCurrentAttempt(descriptor) else {
            finishTransfer(descriptor)
            return
        }
        if let underlyingError, DownloadFailurePolicy.isCancellation(underlyingError) {
            failAttemptWithoutRetry(descriptor, error: "下载已取消")
            finishTransfer(descriptor)
            return
        }
        var next = descriptor
        next.domainIndex += 1
        if next.imageDomains.indices.contains(next.domainIndex) {
            startForegroundTransfer(next)
            return
        }
        failAttemptWithoutRetry(descriptor, error: error)
        finishTransfer(descriptor)
    }

    private func transferToken(for descriptor: PageDownloadDescriptor) -> String {
        "\(descriptor.attemptToken):\(descriptor.comic.id):\(descriptor.chapterID):\(descriptor.pageIndex)"
    }

    private func finishTransfer(_ descriptor: PageDownloadDescriptor) {
        let token = transferToken(for: descriptor)
        Task { await transferLimiter.release(token: token) }
    }

    private func isCurrentAttempt(_ descriptor: PageDownloadDescriptor) -> Bool {
        attemptRegistry.isCurrent(
            progressID: descriptor.progressID,
            token: descriptor.attemptToken
        )
    }

    private func failAttemptWithoutRetry(
        _ descriptor: PageDownloadDescriptor,
        error: String
    ) {
        guard isCurrentAttempt(descriptor) else { return }
        setTerminallyFailed(true, progressID: descriptor.progressID)
        cancelDecodeWorks(progressID: descriptor.progressID)
        removeGloballyDeferredDescriptors { $0.progressID == descriptor.progressID }
        foregroundSession.getAllTasks { tasks in
            for task in tasks {
                guard let candidate = self.descriptor(for: task),
                      candidate.progressID == descriptor.progressID,
                      candidate.attemptToken == descriptor.attemptToken else { continue }
                task.cancel()
            }
        }
        DispatchQueue.main.async {
            let pending = self.takePendingProgressPublish(id: descriptor.progressID)
            // Publish partial completed pages once at the failed-attempt
            // boundary instead of rebuilding the library for every page.
            self.requestLibraryReload { reloadResult in
                guard self.attemptRegistry.finishIfCurrent(
                    progressID: descriptor.progressID,
                    token: descriptor.attemptToken
                ) else { return }
                self.updateProgress(id: descriptor.progressID) {
                    if pending?.attemptToken == descriptor.attemptToken {
                        $0.completedPages = max($0.completedPages, pending?.completedPages ?? 0)
                    }
                    $0.state = .failed
                    if case let .failure(reloadError) = reloadResult {
                        $0.error = error
                            + "\n刷新离线索引失败："
                            + reloadError.localizedDescription
                    } else {
                        $0.error = error
                    }
                }
            }
        }
    }

    private var isGlobalPauseRequested: Bool {
        globalControlLock.lock()
        defer { globalControlLock.unlock() }
        return globalPauseRequested
    }

    /// URLSession returns its task list asynchronously. A generation check
    /// prevents an older resume callback from undoing a newer pause (or vice
    /// versa) when the controls are tapped in quick succession.
    private func applySessionControl(
        tasks: [URLSessionTask],
        paused: Bool,
        generation: UInt
    ) {
        globalControlLock.lock()
        guard globalPauseRequested == paused,
              globalControlGeneration == generation else {
            globalControlLock.unlock()
            return
        }
        if paused {
            for task in tasks where task.state == .running { task.suspend() }
        } else {
            for task in tasks where task.state == .suspended { task.resume() }
        }
        globalControlLock.unlock()

        guard paused else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.globalControlLock.lock()
            let pauseIsCurrent = self.globalPauseRequested
                && self.globalControlGeneration == generation
            self.globalControlLock.unlock()
            guard pauseIsCurrent else { return }
            // A pause is one UI boundary for the current burst. Reload once so
            // partial pages are visible without per-page library publication.
            self.requestLibraryReload()
        }
    }

    private func removeGloballyDeferredDescriptors(
        where shouldRemove: (PageDownloadDescriptor) -> Bool
    ) {
        globalControlLock.lock()
        let removedTokens = globallyDeferredDescriptors.compactMap { token, descriptor in
            shouldRemove(descriptor) ? token : nil
        }
        for token in removedTokens { globallyDeferredDescriptors.removeValue(forKey: token) }
        globalControlLock.unlock()
        // Removed entries own real limiter permits. They cannot be awaited from
        // the synchronous delete/failure paths, but no replacement uses the same
        // attempt token, so asynchronous release cannot race a new acquire.
        for token in removedTokens {
            Task { await transferLimiter.release(token: token) }
        }
    }

    private func completedRecordCount(comicID: String, chapterID: String) -> Int {
        guard let records = try? database?.pageRecords(comicID: comicID, chapterID: chapterID) else { return 0 }
        return records.filter {
            $0.completed && FileManager.default.fileExists(atPath: offlineRoot.appendingPathComponent($0.relativePath).path)
        }.count
    }

    /// Repairs reservations written by builds that truncated by Character
    /// count. SQLite accepts such paths, but APFS cannot create their directory
    /// or file component. A reservation is rewritten before a task is started;
    /// an already completed file is moved and keeps its completed state.
    private func repairUnsafeReservedPaths(
        _ records: [OfflinePageRecord],
        comic: ComicSummary,
        storageDirectoryName: String,
        chapterDirectoryName: String,
        database: OfflineLibraryDatabase
    ) throws -> [OfflinePageRecord] {
        var repaired: [OfflinePageRecord] = []
        repaired.reserveCapacity(records.count)

        for record in records {
            guard !DownloadStorageNaming.isSafeRelativePagePath(
                record.relativePath,
                directoryName: storageDirectoryName,
                chapterDirectoryName: chapterDirectoryName
            ) else {
                repaired.append(record)
                continue
            }

            let newRelativePath = visibleRelativePath(
                for: comic,
                storageDirectoryName: storageDirectoryName,
                chapterDirectoryName: chapterDirectoryName,
                imageNumber: record.globalOrdinal,
                fileExtension: (record.relativePath as NSString).pathExtension
            )
            let source = offlineRoot.appendingPathComponent(record.relativePath)
            let destination = offlineRoot.appendingPathComponent(newRelativePath)

            var remainsCompleted = false
            if record.completed {
                do {
                    remainsCompleted = try DownloadPathMigration.moveCompletedFileThenCommit(
                        source: source,
                        destination: destination,
                        createDestinationDirectory: {
                            try self.createVisibleDirectory(destination.deletingLastPathComponent())
                        },
                        commitIndex: { remainsCompleted in
                            if remainsCompleted {
                                try database.upsertPage(
                                    chapterID: record.chapterID,
                                    pageIndex: record.pageIndex,
                                    globalOrdinal: record.globalOrdinal,
                                    relativePath: newRelativePath
                                )
                            } else {
                                // A completed bit without either physical file
                                // is repaired into an ordinary pending download.
                                try database.reservePage(
                                    chapterID: record.chapterID,
                                    pageIndex: record.pageIndex,
                                    globalOrdinal: record.globalOrdinal,
                                    relativePath: newRelativePath
                                )
                            }
                        }
                    )
                } catch {
                    if let storageError = error as? DownloadStorageError {
                        NSLog("[JMComic] %@", storageError.localizedDescription)
                        throw storageError
                    }
                    let wrapped = DownloadStorageError.migrateFile(
                        from: source,
                        to: destination,
                        underlying: error as NSError
                    )
                    NSLog("[JMComic] %@", wrapped.localizedDescription)
                    throw wrapped
                }
            } else {
                // No completed file is owned by this row, so changing the
                // reservation itself is a single SQLite transaction.
                try database.reservePage(
                    chapterID: record.chapterID,
                    pageIndex: record.pageIndex,
                    globalOrdinal: record.globalOrdinal,
                    relativePath: newRelativePath
                )
            }

            NSLog(
                "[JMComic] Repaired download path for chapter %@ page %d: %lu/%lu UTF-8 bytes",
                record.chapterID,
                record.pageIndex + 1,
                record.relativePath.utf8.count,
                newRelativePath.utf8.count
            )
            repaired.append(OfflinePageRecord(
                chapterID: record.chapterID,
                pageIndex: record.pageIndex,
                globalOrdinal: record.globalOrdinal,
                relativePath: newRelativePath,
                completed: remainsCompleted
            ))
        }
        return repaired
    }

    private func createVisibleDirectory(_ directory: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            // File protection is useful but must not make an otherwise valid,
            // user-visible download fail on a sideloaded build/files provider.
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: directory.path
            )
        } catch {
            throw DownloadStorageError.createDirectory(directory, error as NSError)
        }
    }

    private func writeVisibleImage(_ data: Data, to destination: URL) throws {
        try createVisibleDirectory(destination.deletingLastPathComponent())
        do {
            try data.write(to: destination, options: .atomic)
            // The image is already durable. Treat protection-attribute support
            // as best effort instead of deleting/re-downloading a good file.
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )
        } catch {
            throw DownloadStorageError.writeFile(destination, error as NSError)
        }
    }

    private func failForLocalStorage(
        _ descriptor: PageDownloadDescriptor,
        destination: URL,
        error: Error
    ) {
        guard isCurrentAttempt(descriptor) else { return }
        let details = "\(error.localizedDescription) [directory-bytes="
            + "\(destination.deletingLastPathComponent().lastPathComponent.utf8.count), "
            + "file-bytes=\(destination.lastPathComponent.utf8.count)]"
        NSLog("[JMComic] Local download storage failure at %@: %@", destination.path, details)
        failAttemptWithoutRetry(descriptor, error: details)
    }

    private func resolvedStorageDirectoryName(for comic: ComicSummary) throws -> String {
        // The published library is intentionally not rebuilt for every page.
        // Consult SQLite once when enqueueing so a paused/failed partial comic
        // continues using its already-owned directory.
        let indexedLibrary = (try? database?.loadLibrary()) ?? library
        if let existing = indexedLibrary.first(where: { $0.id == comic.id }),
           DownloadStorageNaming.isSafeComponent(existing.storageDirectoryName),
           existing.storageDirectoryName.utf8.count <= DownloadStorageNaming.generatedComponentByteLimit {
            return existing.storageDirectoryName
        }
        let preferred = visibleFolderName(for: comic)
        let isUsedByAnotherComic = indexedLibrary.contains {
            $0.id != comic.id && $0.storageDirectoryName == preferred
        }
        let directory = offlineRoot.appendingPathComponent(preferred, isDirectory: true)
        let hasUnownedFiles = !((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).isEmpty
        if isUsedByAnotherComic || hasUnownedFiles {
            return DownloadStorageNaming.disambiguatedFolderName(preferred, comicID: comic.id)
        }
        return preferred
    }

    private func visibleRelativePath(
        for comic: ComicSummary,
        storageDirectoryName: String,
        chapterDirectoryName: String,
        imageNumber: Int,
        fileExtension: String = "jpg"
    ) -> String {
        DownloadStorageNaming.relativePath(
            comicName: comic.name,
            storageDirectoryName: storageDirectoryName,
            chapterDirectoryName: chapterDirectoryName,
            imageNumber: imageNumber,
            fileExtension: fileExtension
        )
    }

    private func visibleChapterDirectoryName(for chapter: Chapter, comicID: String) -> String {
        let base = DownloadStorageNaming.chapterFolderName(chapterTitle: chapter.title)
        guard let chapters = (try? database?.loadLibrary())?
            .first(where: { $0.id == comicID })?.chapters,
              chapters.contains(where: {
                  $0.id != chapter.id
                      && DownloadStorageNaming.chapterFolderName(chapterTitle: $0.title) == base
              }) else { return base }
        return DownloadStorageNaming.disambiguatedChapterFolderName(
            chapterTitle: chapter.title,
            chapterID: chapter.id
        )
    }

    private func visibleFolderName(for comic: ComicSummary) -> String {
        DownloadStorageNaming.folderName(for: comic)
    }

    private func migrateLegacyStorageIfNeeded() {
        guard let database,
              ((try? database.loadLibrary()) ?? []).isEmpty else { return }
        let candidates = [
            (documentsRoot.appendingPathComponent("library.json"), documentsRoot),
            (offlineRoot.appendingPathComponent("library.json"), offlineRoot),
            (legacyRoot.appendingPathComponent("library.json"), legacyRoot)
        ]
        guard let candidate = candidates.first(where: { FileManager.default.fileExists(atPath: $0.0.path) }),
              let data = try? Data(contentsOf: candidate.0),
              var oldLibrary = try? JSONDecoder().decode([OfflineComic].self, from: data) else { return }

        var migrationError: Error?
        legacyMigration: for comicIndex in oldLibrary.indices {
            let comic = oldLibrary[comicIndex].comic
            let oldDirectoryName = oldLibrary[comicIndex].storageDirectoryName
            let directoryName = DownloadStorageNaming.isSafeComponent(oldDirectoryName)
                && oldDirectoryName.utf8.count <= DownloadStorageNaming.generatedComponentByteLimit
                ? oldDirectoryName
                : visibleFolderName(for: comic)
            oldLibrary[comicIndex].storageDirectoryName = directoryName
            let duplicateChapterNames = Dictionary(grouping: oldLibrary[comicIndex].chapters) {
                DownloadStorageNaming.chapterFolderName(chapterTitle: $0.title)
            }.filter { $0.value.count > 1 }.keys
            var imageNumber = 1
            for chapterIndex in oldLibrary[comicIndex].chapters.indices {
                let offlineChapter = oldLibrary[comicIndex].chapters[chapterIndex]
                let chapter = Chapter(
                    id: offlineChapter.id,
                    title: offlineChapter.title,
                    sort: offlineChapter.sort
                )
                let baseChapterDirectory = DownloadStorageNaming.chapterFolderName(
                    chapterTitle: chapter.title
                )
                let chapterDirectoryName = duplicateChapterNames.contains(baseChapterDirectory)
                    ? DownloadStorageNaming.disambiguatedChapterFolderName(
                        chapterTitle: chapter.title,
                        chapterID: chapter.id
                    )
                    : baseChapterDirectory
                let oldPaths = oldLibrary[comicIndex].chapters[chapterIndex].relativePagePaths
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                var newPaths: [String] = []
                for oldPath in oldPaths {
                    let source = candidate.1.appendingPathComponent(oldPath)
                    var relative = visibleRelativePath(
                        for: comic,
                        storageDirectoryName: directoryName,
                        chapterDirectoryName: chapterDirectoryName,
                        imageNumber: imageNumber
                    )
                    imageNumber += 1
                    var destination = offlineRoot.appendingPathComponent(relative)
                    // A prior interrupted launch may already have moved this
                    // exact file but failed before importing SQLite. The stable
                    // ordinal lets the next launch adopt that destination.
                    if FileManager.default.fileExists(atPath: destination.path),
                       !FileManager.default.fileExists(atPath: source.path) {
                        newPaths.append(relative)
                        continue
                    }
                    guard FileManager.default.fileExists(atPath: source.path) else { continue }
                    while FileManager.default.fileExists(atPath: destination.path), destination != source {
                        relative = visibleRelativePath(
                            for: comic,
                            storageDirectoryName: directoryName,
                            chapterDirectoryName: chapterDirectoryName,
                            imageNumber: imageNumber
                        )
                        imageNumber += 1
                        destination = offlineRoot.appendingPathComponent(relative)
                    }
                    do {
                        try createVisibleDirectory(destination.deletingLastPathComponent())
                        if destination != source {
                            try FileManager.default.moveItem(at: source, to: destination)
                        }
                        newPaths.append(relative)
                    } catch {
                        // Do not import a partial index and delete library.json.
                        // Pages moved before this failure use stable ordinals;
                        // the next launch adopts them and resumes this migration.
                        migrationError = error
                        break legacyMigration
                    }
                }
                oldLibrary[comicIndex].chapters[chapterIndex].relativePagePaths = newPaths
            }
        }
        guard migrationError == nil else { return }
        do {
            try database.importLegacy(oldLibrary) { visibleFolderName(for: $0) }
            try? FileManager.default.removeItem(at: candidate.0)
            if candidate.1 == legacyRoot { try? FileManager.default.removeItem(at: legacyRoot) }
        } catch {
            return
        }
    }

    private func migrateIndexedStorageLayoutIfNeeded() {
        guard let database else { return }
        guard UserDefaults.standard.integer(forKey: DownloadStorageMigration.layoutVersionKey)
                < DownloadStorageMigration.currentLayoutVersion else { return }
        do {
            try DownloadStorageMigration.migrateIndexedLibrary(
                database: database,
                documentsRoot: documentsRoot,
                downloadRoot: offlineRoot
            )
            UserDefaults.standard.set(
                DownloadStorageMigration.currentLayoutVersion,
                forKey: DownloadStorageMigration.layoutVersionKey
            )
        } catch {
            // Keep the original indexed file usable. The migration is
            // transactionally retryable at the next launch or enqueue.
            NSLog("[JMComic] Offline storage migration deferred: %@", error.localizedDescription)
        }
    }

    private func setTombstoned(_ value: Bool, comicID: String) {
        tombstoneLock.lock()
        defer { tombstoneLock.unlock() }
        if value { tombstones.insert(comicID) } else { tombstones.remove(comicID) }
    }

    private func isTombstoned(comicID: String) -> Bool {
        tombstoneLock.lock()
        defer { tombstoneLock.unlock() }
        return tombstones.contains(comicID)
    }

    private func setTerminallyFailed(_ value: Bool, progressID: String) {
        terminalFailureLock.lock()
        defer { terminalFailureLock.unlock() }
        if value { terminallyFailedProgressIDs.insert(progressID) }
        else { terminallyFailedProgressIDs.remove(progressID) }
    }

    private func isTerminallyFailed(progressID: String) -> Bool {
        terminalFailureLock.lock()
        defer { terminalFailureLock.unlock() }
        return terminallyFailedProgressIDs.contains(progressID)
    }

    @MainActor
    private func upsertProgress(_ value: ChapterDownloadProgress) {
        if let index = progress.firstIndex(where: { $0.id == value.id }) { progress[index] = value }
        else { progress.insert(value, at: 0) }
    }

    @MainActor
    private func updateProgress(id: String, mutation: (inout ChapterDownloadProgress) -> Void) {
        guard let index = progress.firstIndex(where: { $0.id == id }) else { return }
        mutation(&progress[index])
    }

    /// Coalesces nearby chapter/failure/pause boundaries into the newest
    /// SQLite snapshot. The full read runs on a utility task and the library
    /// plus its boundary-specific progress mutation publish in one MainActor
    /// turn.
    @MainActor
    private func requestLibraryReload(
        completion: ((Result<[OfflineComic], Error>) -> Void)? = nil
    ) {
        libraryReloadRevision &+= 1
        if let completion { libraryReloadCompletions.append(completion) }
        guard libraryReloadTask == nil else { return }

        libraryReloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                // Let completions enqueued in the same main-queue burst join
                // this read without imposing a fixed wall-clock delay.
                await Task.yield()
                let targetRevision = self.libraryReloadRevision
                let result: Result<[OfflineComic], Error>
                if let database = self.database {
                    result = await Task.detached(priority: .utility) {
                        Result { try database.loadLibrary() }
                    }.value
                } else {
                    result = .failure(
                        OfflineLibraryDatabaseError.invalidData("数据库未初始化")
                    )
                }

                // A later request may correspond to a database commit that
                // happened while this read was in flight. Read once more and
                // only publish the newest coherent snapshot.
                guard targetRevision == self.libraryReloadRevision else { continue }
                let completions = self.libraryReloadCompletions
                self.libraryReloadCompletions.removeAll(keepingCapacity: true)
                self.libraryReloadTask = nil
                if case let .success(library) = result {
                    self.library = library
                }
                completions.forEach { $0(result) }
                return
            }
            self.libraryReloadTask = nil
        }
    }

    /// Publishes page counters at most once per 125 ms burst. Database page
    /// records are already committed before this method is called, so delaying
    /// only the presentation value cannot affect pause/resume or recovery.
    @MainActor
    private func scheduleProgressPublish(
        id: String,
        completedPages: Int,
        totalPages: Int,
        attemptToken: String
    ) {
        let previous = pendingProgressPublishes[id]
        let coalescedCompletedPages = previous?.attemptToken == attemptToken
            ? max(previous?.completedPages ?? 0, completedPages)
            : completedPages
        pendingProgressPublishes[id] = PendingProgressPublish(
            completedPages: coalescedCompletedPages,
            totalPages: totalPages,
            attemptToken: attemptToken
        )
        guard progressPublishTasks[id] == nil else { return }

        progressPublishTasks[id] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(125))
            } catch {
                return
            }
            guard let self else { return }
            self.progressPublishTasks[id] = nil
            guard let pending = self.pendingProgressPublishes.removeValue(forKey: id),
                  self.attemptRegistry.isCurrent(
                    progressID: id,
                    token: pending.attemptToken
                  ) else { return }
            self.updateProgress(id: id) {
                $0.completedPages = max($0.completedPages, pending.completedPages)
                $0.totalPages = max($0.totalPages, pending.totalPages)
            }
        }
    }

    @MainActor
    private func cancelPendingProgressPublish(id: String) {
        _ = takePendingProgressPublish(id: id)
    }

    @MainActor
    private func takePendingProgressPublish(id: String) -> PendingProgressPublish? {
        progressPublishTasks.removeValue(forKey: id)?.cancel()
        return pendingProgressPublishes.removeValue(forKey: id)
    }
}
