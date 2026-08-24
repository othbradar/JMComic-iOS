import Foundation

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
