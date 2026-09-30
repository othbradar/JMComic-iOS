import Foundation
import UIKit
import ImageIO
import Darwin

/// A page's consumers can change urgency without replacing its network task.
final class PageLoadUrgency: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var visible: Bool
    private var priorityObserver: (@Sendable () -> Void)?
    private let tasks = NSHashTable<URLSessionTask>.weakObjects()
    init(visible: Bool) { self.visible = visible }
    var isVisible: Bool { lock.lock(); defer { lock.unlock() }; return visible }
    var priority: TaskPriority { isVisible ? .userInitiated : .utility }
    func setVisible(_ value: Bool) {
        lock.lock()
        visible = value
        for task in tasks.allObjects { task.priority = value ? URLSessionTask.highPriority : URLSessionTask.lowPriority }
        let observer = priorityObserver
        lock.unlock()
        observer?()
    }
    func observePriority(_ observer: @escaping @Sendable () -> Void) {
        lock.lock(); priorityObserver = observer; lock.unlock()
    }
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.lock()
        tasks.add(task)
        task.priority = visible ? URLSessionTask.highPriority : URLSessionTask.lowPriority
        lock.unlock()
    }
}

enum ReadingImageError: LocalizedError {
    case resourceLimit, fileChanged
    var errorDescription: String? {
        switch self {
        case .resourceLimit: return "图片超出当前解码内存预算，请关闭其他阅读页面后重试；未降低清晰度"
        case .fileChanged: return "图片文件已更新，请重试"
        }
    }
}

enum ReadingImageHeader {
    static func size(data: Data) throws -> CGSize {
        try size(source: CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary))
    }
    static func size(url: URL) throws -> CGSize {
        try size(source: CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary))
    }
    private static func size(source: CGImageSource?) throws -> CGSize {
        guard let source,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0 else { throw ImageScrambler.ImageError.invalidImage }
        return CGSize(width: width.doubleValue, height: height.doubleValue)
    }
}

/// Shared page-only soft budget: retained cache + encoded buffers + estimated
/// raster/descramble/encoding workspace. UIKit and ImageIO can retain additional
/// memory; this deliberately isn't advertised as a process-wide hard ceiling.
@MainActor
final class ReadingImageMemory {
    static let shared = ReadingImageMemory()
    private struct Cached { let image: UIImage; let bytes: Int; var touch: UInt64 }
    private struct Waiter {
        let id: UUID
        let bytes: Int
        let urgency: PageLoadUrgency
        let continuation: CheckedContinuation<Void, Error>
    }
    let softBytes: Int
    let maximumImageBytes: Int
    let maximumDecodes: Int
    private let cacheLimit: Int
    private var cache: [String: Cached] = [:]
    private(set) var cacheBytes = 0
    private var clock: UInt64 = 0
    private var buffered: [UUID: Int] = [:]
    private var active: [UUID: Int] = [:]
    private var waiters: [Waiter] = []
    private var warningObserver: NSObjectProtocol?
    var activeDecodeCount: Int { active.count }
    var bufferedBytes: Int { buffered.values.reduce(0, +) }
    var activeBytes: Int { active.values.reduce(0, +) }

    init(softBytes: Int = 192 * 1_024 * 1_024, maximumImageBytes: Int = 512 * 1_024 * 1_024,
         maximumDecodes: Int = 2, cacheBytes: Int = 64 * 1_024 * 1_024) {
        self.softBytes = softBytes
        self.maximumImageBytes = maximumImageBytes
        self.maximumDecodes = maximumDecodes
        self.cacheLimit = min(cacheBytes, softBytes)
        warningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.trimCache(to: 0) } }
    }
    deinit { if let warningObserver { NotificationCenter.default.removeObserver(warningObserver) } }

    func image(for key: String) -> UIImage? {
        guard var entry = cache[key] else { return nil }
        clock &+= 1; entry.touch = clock; cache[key] = entry
        return entry.image
    }
    func insert(_ image: UIImage, key: String) {
        guard let cg = image.cgImage else { return }
        let cost = cg.bytesPerRow * cg.height
        remove(prefix: key, exact: true)
        let available = min(cacheLimit, max(0, softBytes - activeBytes - bufferedBytes))
        guard cost <= available else { return }
        trimCache(to: available - cost, maximumCount: 11)
        clock &+= 1
        cache[key] = Cached(image: image, bytes: cost, touch: clock)
        cacheBytes += cost
    }
    func remove(prefix: String, exact: Bool = false) {
        for key in cache.keys.filter({ exact ? $0 == prefix : $0.hasPrefix(prefix) }) {
            cacheBytes -= cache.removeValue(forKey: key)?.bytes ?? 0
        }
    }
    private func trimCache(to bytes: Int, maximumCount: Int = 12) {
        while cacheBytes > max(0, bytes) || cache.count > maximumCount {
            guard let oldest = cache.min(by: { $0.value.touch < $1.value.touch })?.key else { break }
            cacheBytes -= cache.removeValue(forKey: oldest)?.bytes ?? 0
        }
    }

    func retainInput(_ bytes: Int, id: UUID) throws {
        // Bound pending compressed buffers too; refusing an exceptional input
        // is recoverable and never silently substitutes a smaller image.
        guard bytes <= 64 * 1_024 * 1_024, bufferedBytes + bytes <= softBytes else {
            throw ReadingImageError.resourceLimit
        }
        buffered[id] = bytes
        trimCache(to: min(cacheLimit, softBytes - bufferedBytes - activeBytes))
    }
    func releaseInput(_ id: UUID) { buffered[id] = nil; drain() }

    func acquire(id: UUID, size: CGSize, bytesPerPixel: Int, urgency: PageLoadUrgency) async throws {
        let estimate = size.width * size.height * CGFloat(bytesPerPixel)
        guard estimate.isFinite, estimate > 0, estimate <= CGFloat(maximumImageBytes) else {
            throw ReadingImageError.resourceLimit
        }
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                waiters.append(Waiter(id: id, bytes: Int(estimate), urgency: urgency, continuation: continuation))
                drain()
            }
        } onCancel: { Task { @MainActor in self.cancel(id) } }
        if Task.isCancelled { release(id); throw CancellationError() }
    }
    func release(_ id: UUID) { active[id] = nil; drain() }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        drain()
    }
    func reprioritize() { drain() }
    private func drain() {
        while active.count < maximumDecodes, !waiters.isEmpty {
            let index = waiters.firstIndex(where: { $0.urgency.isVisible }) ?? 0
            let next = waiters[index]
            let fits = activeBytes + bufferedBytes + next.bytes <= softBytes
            // A single large image may exceed the soft budget exclusively. A
            // fixed absolute safety limit above prevents a permanent waiter.
            guard fits || active.isEmpty else { return }
            trimCache(to: min(cacheLimit, softBytes - activeBytes - bufferedBytes - next.bytes))
            let waiter = waiters.remove(at: index)
            active[waiter.id] = waiter.bytes
            waiter.continuation.resume()
        }
    }

    func decode<T: Sendable>(data: Data, urgency: PageLoadUrgency, bytesPerPixel: Int = 16,
                             consume: @escaping @Sendable (T) async throws -> Void = { _ in },
                             operation: @escaping @Sendable () throws -> T) async throws -> T {
        let id = UUID()
        try retainInput(data.count, id: id)
        defer { releaseInput(id) }
        let size = try await Task.detached(priority: urgency.priority) { try ReadingImageHeader.size(data: data) }.value
        try await acquire(id: id, size: size, bytesPerPixel: bytesPerPixel, urgency: urgency)
        defer { release(id) }
        let worker = Task.detached(priority: urgency.priority) {
            try Task.checkCancellation()
            return try autoreleasepool { try operation() }
        }
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        // Download PNG/JPEG output remains resident until its serial file/index
        // commit finishes. Keep its workspace charged across that I/O wait.
        try await consume(result)
        return result
    }
}

/// Page-specific sharing. Each waiting SwiftUI row/prefetch owns a continuation;
/// losing one consumer doesn't cancel another's work. Last release retires the
/// generation immediately, including while an uncancellable ImageIO call exits.
@MainActor
final class ReadingImageLoader {
    typealias Metadata = @MainActor (CGSize) -> Void
    private struct Consumer { var visible: Bool; let prefetchOnly: Bool; let continuation: CheckedContinuation<UIImage, Error>; let metadata: Metadata }
    private final class Load {
        let id = UUID()
        let urgency: PageLoadUrgency
        var consumers: [UUID: Consumer] = [:]
        var size: CGSize?
        var task: Task<Void, Never>?
        init(visible: Bool) { urgency = PageLoadUrgency(visible: visible) }
    }
    private static let staging = AsyncPermitPool(limit: 3, reservedVisibleSlots: 1)
    private let namespace = UUID().uuidString + "|"
    private let memory: ReadingImageMemory
    private var loads: [String: Load] = [:]
    private var sizes: [String: CGSize] = [:]
    private var sizeOrder: [String] = []
    private var warningObserver: NSObjectProtocol?
    init(memory: ReadingImageMemory? = nil) {
        self.memory = memory ?? .shared
        warningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.cancelSpeculation() } }
    }
    deinit {
        if let warningObserver { NotificationCenter.default.removeObserver(warningObserver) }
        for load in loads.values { load.task?.cancel() }
    }
    var inFlightCount: Int { loads.count }
    func knownSize(key: String) -> CGSize? { sizes[key] }
    func image(key: String, consumer: UUID = UUID(), visible: Bool = true, prefetchOnly: Bool = false,
               metadata: @escaping Metadata = { _ in },
               source: @escaping @MainActor (PageLoadUrgency, @escaping Metadata) async throws -> Data,
               validate: @escaping @MainActor () async throws -> Void = {},
               decode: @escaping @Sendable (Data) throws -> UIImage) async throws -> UIImage {
        try Task.checkCancellation()
        if let size = sizes[key] { metadata(size) }
        if let image = memory.image(for: namespace + key) { return image }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let load: Load
                let isNew: Bool
                if let existing = loads[key] { load = existing; isNew = false }
                else { load = Load(visible: visible); loads[key] = load; isNew = true }
                load.consumers[consumer] = Consumer(visible: visible, prefetchOnly: prefetchOnly, continuation: continuation, metadata: metadata)
                if let size = load.size { metadata(size) }
                updateUrgency(load)
                guard isNew else { return }
                load.task = Task { [weak self, weak load] in
                    guard let self, let load else { return }
                    do {
                        try await Self.staging.acquire(priority: load.urgency.priority, limit: 3, urgency: load.urgency)
                        let result: UIImage
                        do {
                            try Task.checkCancellation()
                            let data = try await source(load.urgency) { [weak self] size in
                                self?.publish(size: size, key: key, id: load.id)
                            }
                            try Task.checkCancellation()
                            let size = try await Task.detached(priority: load.urgency.priority) { try ReadingImageHeader.size(data: data) }.value
                            self.publish(size: size, key: key, id: load.id)
                            result = try await self.memory.decode(data: data, urgency: load.urgency) { try decode(data) }
                            try await validate()
                            try Task.checkCancellation()
                            await Self.staging.release()
                        } catch { await Self.staging.release(); throw error }
                        self.finish(key: key, id: load.id, result: .success(result))
                    } catch { self.finish(key: key, id: load.id, result: .failure(error)) }
                }
            }
        } onCancel: { Task { @MainActor in self.release(key: key, consumer: consumer) } }
    }
    func setVisible(_ visible: Bool, key: String, consumer: UUID) {
        guard let load = loads[key], load.consumers[consumer] != nil else { return }
        load.consumers[consumer]?.visible = visible
        updateUrgency(load)
    }
    private func updateUrgency(_ load: Load) {
        load.urgency.setVisible(load.consumers.values.contains(where: \.visible))
        memory.reprioritize()
        Task { await Self.staging.reprioritize() }
    }
    private func publish(size: CGSize, key: String, id: UUID) {
        guard let load = loads[key], load.id == id else { return }
        load.size = size
        sizes[key] = size
        sizeOrder.removeAll { $0 == key }; sizeOrder.append(key)
        while sizeOrder.count > 256 { sizes[sizeOrder.removeFirst()] = nil }
        for consumer in load.consumers.values { consumer.metadata(size) }
    }
    private func finish(key: String, id: UUID, result: Result<UIImage, Error>) {
        guard let load = loads[key], load.id == id else { return }
        loads[key] = nil
        if case .success(let image) = result { memory.insert(image, key: namespace + key) }
        for consumer in load.consumers.values { consumer.continuation.resume(with: result) }
    }
    private func release(key: String, consumer: UUID) {
        guard let load = loads[key], let removed = load.consumers.removeValue(forKey: consumer) else { return }
        removed.continuation.resume(throwing: CancellationError())
        if load.consumers.isEmpty { loads[key] = nil; load.task?.cancel() }
        else { updateUrgency(load) }
    }
    private func cancelSpeculation() {
        for (key, load) in loads {
            for (id, consumer) in load.consumers where consumer.prefetchOnly && !consumer.visible { release(key: key, consumer: id) }
        }
    }
    func evictCached(prefix: String) { memory.remove(prefix: namespace + prefix) }
    func invalidate(prefix: String) {
        memory.remove(prefix: namespace + prefix)
        for key in sizes.keys.filter({ $0.hasPrefix(prefix) }) { sizes[key] = nil }
        sizeOrder.removeAll { $0.hasPrefix(prefix) }
        for (key, load) in loads where key.hasPrefix(prefix) {
            loads[key] = nil; load.task?.cancel()
            for consumer in load.consumers.values { consumer.continuation.resume(throwing: CancellationError()) }
        }
    }
}

@MainActor
final class ReadingPrefetchWindow {
    private var owners: [UUID: [String: Task<Void, Never>]] = [:]
    func update(owner: UUID, prefix: String, indices: [Int], load: @escaping @MainActor (Int) async -> Void) {
        let wanted = Set(indices.map { prefix + "|\($0)" })
        var tasks = owners[owner] ?? [:]
        for key in tasks.keys.filter({ !wanted.contains($0) }) { tasks.removeValue(forKey: key)?.cancel() }
        for index in indices where tasks[prefix + "|\(index)"] == nil {
            tasks[prefix + "|\(index)"] = Task { await load(index) }
        }
        owners[owner] = tasks
    }
    func cancel(owner: UUID) { owners.removeValue(forKey: owner)?.values.forEach { $0.cancel() } }
}

struct LocalPageVersion: Equatable, Sendable {
    let identity: String
    static func read(_ url: URL) throws -> Self {
        var value = stat()
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        defer { Darwin.close(descriptor) }
        guard fstat(descriptor, &value) == 0 else { throw CocoaError(.fileReadUnknown) }
        return Self(identity: "\(value.st_dev)|\(value.st_ino)|\(value.st_size)|\(value.st_mtimespec.tv_sec).\(value.st_mtimespec.tv_nsec)|\(value.st_ctimespec.tv_sec).\(value.st_ctimespec.tv_nsec)")
    }
}

@MainActor
final class LocalPageImages {
    static let shared = LocalPageImages()
    static let filesChanged = Notification.Name("JMComic.ReadingFilesChanged")
    private let loader: ReadingImageLoader
    private let prefetch = ReadingPrefetchWindow()
    private var versions: [String: String] = [:]
    private var consumerKeys: [UUID: String] = [:]
    private var consumerVisibility: [UUID: Bool] = [:]
    init(memory: ReadingImageMemory? = nil) { loader = ReadingImageLoader(memory: memory) }
    private func prefix(_ url: URL) -> String { "stored-pixels-v1|\(url.standardizedFileURL.absoluteString)|" }
    func image(url: URL, consumer: UUID = UUID(), visible: Bool = true, prefetchOnly: Bool = false,
               metadata: @escaping ReadingImageLoader.Metadata = { _ in }) async throws -> UIImage {
        consumerVisibility[consumer] = visible
        defer { consumerKeys[consumer] = nil; consumerVisibility[consumer] = nil }
        for attempt in 0...1 {
            try Task.checkCancellation()
            let version = try await Task.detached(priority: .utility) { try LocalPageVersion.read(url) }.value
            let prefix = prefix(url)
            if versions[prefix] != version.identity {
                loader.evictCached(prefix: prefix)
                if versions.count >= 256 { versions.removeAll(keepingCapacity: true) }
                versions[prefix] = version.identity
            }
            let key = prefix + version.identity
            consumerKeys[consumer] = key
            do {
                let image = try await loader.image(key: key, consumer: consumer, visible: consumerVisibility[consumer] ?? visible, prefetchOnly: prefetchOnly, metadata: metadata,
                    source: { _, publish in
                        let size = try await Task.detached(priority: .utility) { try ReadingImageHeader.size(url: url) }.value
                        publish(size)
                        return try await Task.detached(priority: .utility) { try Data(contentsOf: url, options: .mappedIfSafe) }.value
                    }, validate: {
                        let current = try await Task.detached(priority: .utility) { try LocalPageVersion.read(url) }.value
                        guard current == version else { throw ReadingImageError.fileChanged }
                    }, decode: { try ImageScrambler.rasterImage(from: $0) })
                let current = try await Task.detached(priority: .utility) { try LocalPageVersion.read(url) }.value
                guard current == version else { throw ReadingImageError.fileChanged }
                try Task.checkCancellation()
                return image
            } catch ReadingImageError.fileChanged where attempt == 0 { continue }
        }
        throw ReadingImageError.fileChanged
    }
    func setVisible(_ visible: Bool, consumer: UUID) {
        if consumerVisibility[consumer] != nil { consumerVisibility[consumer] = visible }
        if let key = consumerKeys[consumer] { loader.setVisible(visible, key: key, consumer: consumer) }
    }
    func updatePrefetch(owner: UUID, urls: [URL], around index: Int, count: Int) {
        prefetch.update(owner: owner, prefix: urls.first?.deletingLastPathComponent().absoluteString ?? "",
                        indices: PageImagePreferences.prefetchIndices(around: index, total: urls.count, count: count)) { [weak self] candidate in
            _ = try? await self?.image(url: urls[candidate], visible: false, prefetchOnly: true)
        }
    }
    func cancelPrefetch(owner: UUID) { prefetch.cancel(owner: owner) }
    func invalidate(urls: [URL]) {
        for url in urls { let key = prefix(url); versions[key] = nil; loader.invalidate(prefix: key) }
        NotificationCenter.default.post(name: Self.filesChanged, object: nil, userInfo: ["urls": urls])
    }
}

/// All final download/cover writes, index commits and deletions run here.
/// Validity is checked inside the same serial boundary as the mutation; no
/// caller waits synchronously on MainActor for another file operation.
final class OfflineFileCommitQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "JMComic.OfflineFileCommit", qos: .utility)
    func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation() }) }
        }
    }
}
