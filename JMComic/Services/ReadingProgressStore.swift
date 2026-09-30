import Foundation

typealias ChapterProgressRecords = [String: [String: ReadingProgress]]

private actor ReadingProgressPersistenceWriter {
    private let defaults: UserDefaults
    private var pendingTask: Task<Void, Never>?
    private var latestRevision: UInt = 0
    init(defaults: UserDefaults) { self.defaults = defaults }
    func schedule(_ snapshot: ChapterProgressRecords, revision: UInt) {
        guard revision > latestRevision else { return }
        latestRevision = revision; pendingTask?.cancel()
        pendingTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(300))
                try Task.checkCancellation()
                guard revision == latestRevision else { return }
                persist(snapshot)
            } catch {}
        }
    }
    func flush(_ snapshot: ChapterProgressRecords, revision: UInt) {
        guard revision >= latestRevision else { return }
        latestRevision = revision; pendingTask?.cancel(); pendingTask = nil
        persist(snapshot)
    }
    private func persist(_ snapshot: ChapterProgressRecords) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: ReadingProgressStore.chaptersKey)
        // Retain the existing most-recent-chapter lookup for older versions.
        let latest = snapshot.compactMapValues { $0.values.max { $0.updatedAt < $1.updatedAt } }
        if let data = try? JSONEncoder().encode(latest) { defaults.set(data, forKey: "jm.reading.progress") }
    }
}

@MainActor
final class ReadingProgressStore: ObservableObject {
    nonisolated static let chaptersKey = "jm.reading.chapter-progress.v1"
    @Published private(set) var values: [String: ReadingProgress] = [:]
    @Published private(set) var chapters: ChapterProgressRecords = [:]
    private let persistenceWriter: ReadingProgressPersistenceWriter
    private var persistenceRevision: UInt = 0
    init(defaults: UserDefaults = .standard) {
        persistenceWriter = ReadingProgressPersistenceWriter(defaults: defaults)
        if let data = defaults.data(forKey: Self.chaptersKey),
           let decoded = try? JSONDecoder().decode(ChapterProgressRecords.self, from: data) { chapters = decoded }
        else if let data = defaults.data(forKey: "jm.reading.progress"),
                let legacy = try? JSONDecoder().decode([String: ReadingProgress].self, from: data) {
            chapters = legacy.mapValues { [$0.chapterID: $0] }
        }
        values = chapters.compactMapValues { $0.values.max { $0.updatedAt < $1.updatedAt } }
    }
    func progress(comicID: String) -> ReadingProgress? { values[comicID] }
    func progress(comicID: String, chapterID: String) -> ReadingProgress? { chapters[comicID]?[chapterID] }
    func update(comicID: String, chapterID: String, pageIndex: Int) {
        if let current = values[comicID], current.chapterID == chapterID, current.pageIndex == pageIndex { return }
        let progress = ReadingProgress(chapterID: chapterID, pageIndex: pageIndex, updatedAt: .now)
        chapters[comicID, default: [:]][chapterID] = progress
        values[comicID] = progress
        persistenceRevision &+= 1
        let snapshot = chapters, revision = persistenceRevision
        Task { await persistenceWriter.schedule(snapshot, revision: revision) }
    }
    func merge(_ incoming: ChapterProgressRecords) async {
        for (comic, records) in incoming {
            for (chapter, value) in records where value.updatedAt > (chapters[comic]?[chapter]?.updatedAt ?? .distantPast) {
                chapters[comic, default: [:]][chapter] = value
            }
        }
        values = chapters.compactMapValues { $0.values.max { $0.updatedAt < $1.updatedAt } }
        persistenceRevision &+= 1
        await persistenceWriter.flush(chapters, revision: persistenceRevision)
    }
    func flush() {
        let snapshot = chapters, revision = persistenceRevision
        Task { await persistenceWriter.flush(snapshot, revision: revision) }
    }
}
