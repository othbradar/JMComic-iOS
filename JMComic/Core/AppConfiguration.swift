import Foundation

enum PageImageProcessing: String, Codable, Sendable {
    case faithful
    case repairChroma

    // Only derived reading images use this namespace; CDN bytes, covers and
    // completed offline files are not invalidated when processing changes.
    var cacheIdentifier: String { "page-pixels-v2|\(rawValue)" }
}

enum PageImageStorage: String, Codable, CaseIterable, Sendable {
    case lossless
    case spaceSavingJPEG

    var title: String {
        switch self {
        case .lossless: return "保真保存（原文件 / 无损 PNG）"
        case .spaceSavingJPEG: return "省空间（有损 JPEG）"
        }
    }
}

enum PageImagePreferences {
    static let prefetchCountKey = "reader.prefetchPagesEachSide"
    static let defaultPrefetchCount = 2
    static let prefetchRange = 0...6

    static func prefetchCount(defaults: UserDefaults = .standard) -> Int {
        let value = defaults.object(forKey: prefetchCountKey) == nil
            ? defaultPrefetchCount : defaults.integer(forKey: prefetchCountKey)
        return boundedPrefetchCount(value)
    }
    static func boundedPrefetchCount(_ value: Int) -> Int { min(prefetchRange.upperBound, max(0, value)) }
    static func prefetchIndices(around index: Int, total: Int, count: Int) -> [Int] {
        let count = boundedPrefetchCount(count)
        guard total > 0, count > 0 else { return [] }
        return (1...count).flatMap { [index + $0, index - $0] }.filter { (0..<total).contains($0) }
    }

    static let repairChromaKey = "reader.repairChromaSeams"
    static let storageKey = "downloads.pageImageStorage"

    static func processing(defaults: UserDefaults = .standard) -> PageImageProcessing {
        defaults.bool(forKey: repairChromaKey) ? .repairChroma : .faithful
    }

    static func storage(defaults: UserDefaults = .standard) -> PageImageStorage {
        PageImageStorage(rawValue: defaults.string(forKey: storageKey) ?? "") ?? .lossless
    }
}

struct AppConfiguration: Codable, Equatable {
    static let defaults = AppConfiguration(
        apiDomains: JMServiceAddresses.builtInAPIDomains,
        imageDomains: JMServiceAddresses.builtInImageDomains,
        appVersion: JMServiceAddresses.defaultClientVersion,
        imageShunt: 1,
        contractRevision: JMServiceProtocol.contractRevision
    )

    var apiDomains: [String]
    var imageDomains: [String]
    var appVersion: String
    /// `chapter_view_template` calls this `app_img_shunt`.  It is independent
    /// from the CDN host list and matches the four routes exposed by the
    /// official-style mobile clients.
    var imageShunt: Int
    /// Version of the bundled JM wire contract that last migrated this
    /// persisted configuration. It is deliberately separate from HeaderVer.
    var contractRevision: Int

    static let availableImageShunts = JMServiceAddresses.availableImageShunts

    private enum CodingKeys: String, CodingKey {
        case apiDomains
        case imageDomains
        case appVersion
        case imageShunt
        case contractRevision
    }

    init(
        apiDomains: [String],
        imageDomains: [String],
        appVersion: String,
        imageShunt: Int = 1,
        contractRevision: Int = JMServiceProtocol.contractRevision
    ) {
        self.apiDomains = apiDomains
        self.imageDomains = imageDomains
        self.appVersion = appVersion
        self.imageShunt = Self.clampedImageShunt(imageShunt)
        self.contractRevision = contractRevision
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        apiDomains = try values.decode([String].self, forKey: .apiDomains)
        imageDomains = try values.decode([String].self, forKey: .imageDomains)
        appVersion = try values.decode(String.self, forKey: .appVersion)
        imageShunt = Self.clampedImageShunt(
            try values.decodeIfPresent(Int.self, forKey: .imageShunt) ?? 1
        )
        // Configurations written before the independent contract layer have no
        // revision. Decode them as legacy so `load()` can migrate once.
        contractRevision = try values.decodeIfPresent(Int.self, forKey: .contractRevision) ?? 0
    }

    static func load() -> AppConfiguration {
        guard let data = UserDefaults.standard.data(forKey: "jm.configuration"),
              var value = try? JSONDecoder().decode(Self.self, from: data) else {
            return .defaults
        }
        if value.migrateToCurrentContractIfNeeded() {
            value.save()
        }
        return value
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: "jm.configuration")
    }

    mutating func prioritize(apiDomain: String? = nil, imageDomain: String? = nil) {
        if let apiDomain, !apiDomain.isEmpty {
            let normalized = Self.normalize(apiDomain)
            apiDomains.removeAll { Self.normalize($0) == normalized }
            apiDomains.insert(normalized, at: 0)
        }
        if let imageDomain, !imageDomain.isEmpty {
            let normalized = Self.normalize(imageDomain)
            imageDomains.removeAll { Self.normalize($0) == normalized }
            imageDomains.insert(normalized, at: 0)
        }
    }

    mutating func selectImageShunt(_ value: Int) {
        imageShunt = Self.clampedImageShunt(value)
    }

    /// Keep user/discovered priorities while appending newly bundled fallback
    /// routes. This is idempotent and runs only after the contract revision is
    /// bumped, so an old installation cannot remain stranded on removed hosts.
    @discardableResult
    mutating func migrateToCurrentContractIfNeeded() -> Bool {
        guard contractRevision < JMServiceProtocol.contractRevision else { return false }
        apiDomains = Self.mergingPreferred(apiDomains, fallbacks: JMServiceAddresses.builtInAPIDomains)
        imageDomains = Self.mergingPreferred(imageDomains, fallbacks: JMServiceAddresses.builtInImageDomains)
        appVersion = JMServiceAddresses.defaultClientVersion
        imageShunt = Self.clampedImageShunt(imageShunt)
        contractRevision = JMServiceProtocol.contractRevision
        return true
    }

    static func clampedImageShunt(_ value: Int) -> Int {
        min(max(value, availableImageShunts.first ?? 1), availableImageShunts.last ?? 4)
    }

    static func normalize(_ domain: String) -> String {
        var trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("//") {
            trimmed = "https:" + trimmed
        } else if !trimmed.lowercased().hasPrefix("http://"),
                  !trimmed.lowercased().hasPrefix("https://") {
            trimmed = "https://" + trimmed
        }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    private static func mergingPreferred(_ preferred: [String], fallbacks: [String]) -> [String] {
        var seen: Set<String> = []
        return (preferred + fallbacks).compactMap { value in
            let normalized = normalize(value)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }
}
