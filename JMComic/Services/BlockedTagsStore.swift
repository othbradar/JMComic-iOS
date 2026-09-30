import Foundation

@MainActor
final class BlockedTagsStore: ObservableObject {
    static let shared = BlockedTagsStore()
    static let key = "jm.blocked-tags.v1"
    @Published private(set) var tags: [String]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tags = Self.normalized(defaults.stringArray(forKey: Self.key) ?? [])
    }
    nonisolated static func normalize(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
    nonisolated static func normalized(_ values: [String]) -> [String] {
        Array(Set(values.map(normalize).filter { !$0.isEmpty && $0.utf8.count <= 256 })).sorted().prefix(200).map { $0 }
    }
    func add(_ value: String) { guard tags.count < 200 else { return }; replace(tags + [value]) }
    func mergePreservingExisting(_ values: [String]) {
        let existing = Set(tags)
        let additions = Self.normalized(values).filter { !existing.contains($0) }.prefix(max(0, 200 - tags.count))
        replace(tags + additions)
    }
    func remove(_ value: String) { replace(tags.filter { $0 != value }) }
    func replace(_ values: [String]) {
        tags = Self.normalized(values)
        defaults.set(tags, forKey: Self.key)
    }
    func allows(_ comic: ComicSummary) -> Bool { Self.allows(comic, blocked: Set(tags)) }
    nonisolated static func allows(_ comic: ComicSummary, blocked: Set<String>) -> Bool {
        !comic.tags.contains { blocked.contains(normalize($0)) }
    }
}

/// At most three transports per explicit search/load-more action. Exhaustion
/// considers raw responses, never a locally filtered empty list.
struct FilteredPageBatch {
    var comics: [ComicSummary]
    var nextPage: Int
    var hasMore: Bool
    var serverTotal: Int
    static func load(start: Int, existing: Set<String>, blocked: Set<String>,
                     fetch: (Int) async throws -> (Int, [ComicSummary])) async throws -> Self {
        var result = Self(comics: [], nextPage: start, hasMore: true, serverTotal: 0)
        var seen = existing
        for _ in 0..<3 {
            try Task.checkCancellation()
            let (total, raw) = try await fetch(result.nextPage)
            result.nextPage += 1
            result.serverTotal = total
            let fresh = raw.filter { seen.insert($0.id).inserted }
            result.comics += fresh
            if raw.isEmpty || fresh.isEmpty { result.hasMore = false; break }
            if fresh.contains(where: { BlockedTagsStore.allows($0, blocked: blocked) }) { break }
        }
        return result
    }
}
