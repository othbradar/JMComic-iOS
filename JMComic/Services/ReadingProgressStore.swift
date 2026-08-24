import Foundation

private actor ReadingProgressPersistenceWriter {
    private let key: String
    private var pendingTask: Task<Void, Never>?
    private var latestRevision: UInt = 0

    init(key: String) {
        self.key = key
    }

    func schedule(_ snapshot: [String: ReadingProgress], revision: UInt) {
        guard revision > latestRevision else { return }
        latestRevision = revision
        pendingTask?.cancel()
        pendingTask = Task { [key] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                try Task.checkCancellation()
                guard revision == latestRevision else { return }
                let data = try JSONEncoder().encode(snapshot)
                try Task.checkCancellation()
                UserDefaults.standard.set(data, forKey: key)
            } catch is CancellationError {
                // Rapid page changes intentionally persist only the latest page.
            } catch {
                // Progress remains in memory; a later update retries persistence.
            }
        }
    }

    func flush(_ snapshot: [String: ReadingProgress], revision: UInt) {
        guard revision >= latestRevision else { return }
        latestRevision = revision
        pendingTask?.cancel()
        pendingTask = nil
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

@MainActor
final class ReadingProgressStore: ObservableObject {
    @Published private(set) var values: [String: ReadingProgress] = [:]
    private let key = "jm.reading.progress"
    private lazy var persistenceWriter = ReadingProgressPersistenceWriter(key: key)
    private var persistenceRevision: UInt = 0

    init() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: ReadingProgress].self, from: data) else { return }
        values = decoded
    }

    func progress(comicID: String) -> ReadingProgress? { values[comicID] }

    func update(comicID: String, chapterID: String, pageIndex: Int) {
        if let current = values[comicID],
           current.chapterID == chapterID,
           current.pageIndex == pageIndex {
            return
        }
        values[comicID] = ReadingProgress(chapterID: chapterID, pageIndex: pageIndex, updatedAt: .now)
        persistenceRevision &+= 1
        let snapshot = values
        let revision = persistenceRevision
        Task { await persistenceWriter.schedule(snapshot, revision: revision) }
    }

    /// Reader dismissal commits the latest in-memory page without waiting for
    /// the normal debounce window. Encoding and UserDefaults I/O still run on
    /// the writer actor rather than MainActor.
    func flush() {
        let snapshot = values
        let revision = persistenceRevision
        Task { await persistenceWriter.flush(snapshot, revision: revision) }
    }
}
