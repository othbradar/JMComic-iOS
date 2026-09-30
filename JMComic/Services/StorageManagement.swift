import Foundation
import UIKit

/// Only this cache is disposable. Documents/cache contains shared persistent
/// covers and is deliberately outside the clearing boundary.
final class RebuildableURLCache: URLCache, @unchecked Sendable {
    static let managed = RebuildableURLCache(memoryCapacity: 24 * 1_024 * 1_024,
        diskCapacity: 128 * 1_024 * 1_024, directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("JMComicHTTP"))
    private let fence = NSRecursiveLock()
    private var epoch = UUID().uuidString
    private let property = "JMComic.CacheGeneration"
    func request(_ request: URLRequest) -> URLRequest {
        fence.lock(); defer { fence.unlock() }
        let copy = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(epoch, forKey: property, in: copy)
        return copy as URLRequest
    }
    func clearGeneration() {
        fence.lock(); defer { fence.unlock() }
        epoch = UUID().uuidString
        removeAllCachedResponses()
    }
    override func storeCachedResponse(_ cachedResponse: CachedURLResponse, for request: URLRequest) {
        fence.lock(); defer { fence.unlock() }
        guard URLProtocol.property(forKey: property, in: request) as? String == epoch else { return }
        super.storeCachedResponse(cachedResponse, for: request)
    }
    override func storeCachedResponse(_ cachedResponse: CachedURLResponse, for dataTask: URLSessionDataTask) {
        fence.lock(); defer { fence.unlock() }
        guard let request = dataTask.originalRequest,
              URLProtocol.property(forKey: property, in: request) as? String == epoch else { return }
        super.storeCachedResponse(cachedResponse, for: dataTask)
    }
}

struct StorageUsage: Sendable {
    var downloads: Int64 = 0
    var protectedFiles: Int64 = 0
    var exports: Int64 = 0
    var network: Int64 = 0
    var measuredAt = Date()
}

actor StorageInventory {
    static let shared = StorageInventory()
    private var last: StorageUsage?
    private var measuring: Task<StorageUsage, Error>?
    func usage(documents: URL, exports: URL, force: Bool = false) async throws -> StorageUsage {
        if !force, let last, Date().timeIntervalSince(last.measuredAt) < 30 { return last }
        if let measuring { return try await measuring.value }
        let task = Task.detached(priority: .utility) {
            var seen = Set<String>()
            func count(_ root: URL) throws -> Int64 {
                guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
                var failure: Error?
                guard let walker = FileManager.default.enumerator(at: root,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [],
                    errorHandler: { _, error in failure = error; return false }) else { return 0 }
                var bytes: Int64 = 0
                for case let url as URL in walker {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    if values.isSymbolicLink == true { walker.skipDescendants(); continue }
                    guard values.isRegularFile == true else { continue }
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    let identity = "\(attributes[.systemNumber] ?? "")|\(attributes[.systemFileNumber] ?? url.path)"
                    if seen.insert(identity).inserted { bytes += (attributes[.size] as? NSNumber)?.int64Value ?? 0 }
                }
                if let failure { throw failure }
                return bytes
            }
            var usage = StorageUsage()
            usage.downloads = try count(JMComicStorageLayout.downloadRoot(documentsRoot: documents))
            usage.protectedFiles = try count(JMComicStorageLayout.cacheRoot(documentsRoot: documents))
            usage.protectedFiles += try count(JMComicStorageLayout.databaseURL(documentsRoot: documents).deletingLastPathComponent())
            usage.exports = try count(exports)
            usage.network = Int64(RebuildableURLCache.managed.currentDiskUsage + URLCache.shared.currentDiskUsage)
            return usage
        }
        measuring = task
        defer { measuring = nil }
        let measured = try await task.value
        last = measured
        return measured
    }
    func invalidate() { last = nil }
}

/// Per-export leases: clearing never touches a file being built or shared.
/// After a share completes a grace period allows file providers to finish.
actor ExportFiles {
    static let shared = ExportFiles()
    nonisolated let root: URL
    private var active = Set<UUID>()
    init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("JMComicExports", isDirectory: true)) { self.root = root }
    func begin() throws -> (UUID, URL) {
        let id = UUID()
        // Use the lease ID as the sole directory name; never a imported/user path.
        let owned = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        try setExpiry(.now.addingTimeInterval(24 * 3600), at: owned)
        active.insert(id)
        return (id, owned)
    }
    func finishSharing(_ id: UUID, now: Date = .now) throws {
        guard active.contains(id) else { return }
        let directory = root.appendingPathComponent(id.uuidString)
        try setExpiry(now.addingTimeInterval(600), at: directory)
        active.remove(id)
        Task {
            try? await Task.sleep(for: .seconds(601))
            try? cleanup()
        }
    }
    func discard(_ id: UUID) throws {
        let url = root.appendingPathComponent(id.uuidString)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        active.remove(id)
    }
    func cleanup(now: Date = .now) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            guard let id = UUID(uuidString: url.lastPathComponent), !active.contains(id),
                  try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                  let bytes = try? Data(contentsOf: url.appendingPathComponent("expiry.json")),
                  let expiry = try? JSONDecoder().decode(Date.self, from: bytes), expiry <= now else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }
    private func setExpiry(_ date: Date, at directory: URL) throws {
        try JSONEncoder().encode(date).write(to: directory.appendingPathComponent("expiry.json"), options: .atomic)
    }
}
