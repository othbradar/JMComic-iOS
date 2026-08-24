import CryptoKit
import Foundation
import Security

protocol SecureDataStoring {
    @discardableResult
    func save(_ data: Data, account: String) throws -> KeychainStore.StorageLocation
    func load(account: String) -> Data?
    func delete(account: String)
}

/// Small injectable boundary around Security.framework. Tests can return the exact
/// OSStatus produced by an unsigned simulator/sideload without touching the user's
/// real keychain.
protocol KeychainAccessing {
    func save(_ data: Data, service: String, account: String) -> OSStatus
    func load(service: String, account: String) -> (status: OSStatus, data: Data?)
    func delete(service: String, account: String) -> OSStatus
}

private struct SystemKeychainAccess: KeychainAccessing {
    func save(_ data: Data, service: String, account: String) -> OSStatus {
        let query = baseQuery(service: service, account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return updateStatus }
        guard updateStatus == errSecItemNotFound else { return updateStatus }

        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        return SecItemAdd(item as CFDictionary, nil)
    }

    func load(service: String, account: String) -> (status: OSStatus, data: Data?) {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func delete(service: String, account: String) -> OSStatus {
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

final class KeychainStore: SecureDataStoring {
    enum StorageLocation: Equatable {
        case keychain
        case protectedFile
    }

    enum KeychainError: LocalizedError {
        case status(OSStatus)
        case protectedFallbackUnavailable(OSStatus)
        case protectedFallback(Error)

        var errorDescription: String? {
            switch self {
            case .status(let status):
                return "钥匙串错误（\(status)）"
            case .protectedFallbackUnavailable(let status):
                return "钥匙串不可用（\(status)）且无法初始化本地受保护存储"
            case .protectedFallback(let error):
                return "无法写入本地受保护存储：\(error.localizedDescription)"
            }
        }
    }

    private static let service = "io.github.jmcomic.mobile"
    static let shared = KeychainStore(
        keychain: SystemKeychainAccess(),
        fallbackDirectory: defaultFallbackDirectory()
    )

    private let keychain: any KeychainAccessing
    private let fallback: ProtectedFileFallback?
    private let service: String

    init(
        keychain: any KeychainAccessing,
        fallbackDirectory: URL?,
        service: String = KeychainStore.service,
        fileManager: FileManager = .default
    ) {
        self.keychain = keychain
        self.service = service
        fallback = fallbackDirectory.map {
            ProtectedFileFallback(directory: $0, service: service, fileManager: fileManager)
        }
    }

    @discardableResult
    static func save(_ data: Data, account: String) throws -> StorageLocation {
        try shared.save(data, account: account)
    }

    static func load(account: String) -> Data? {
        shared.load(account: account)
    }

    static func delete(account: String) {
        shared.delete(account: account)
    }

    @discardableResult
    func save(_ data: Data, account: String) throws -> StorageLocation {
        let status = keychain.save(data, service: service, account: account)
        if status == errSecSuccess {
            // If a previously unsigned build used the protected-file fallback, a
            // newly entitled build should leave only the stronger Keychain copy.
            try? fallback?.delete(account: account)
            return .keychain
        }

        guard Self.isKeychainUnavailable(status) else {
            throw KeychainError.status(status)
        }
        guard let fallback else {
            throw KeychainError.protectedFallbackUnavailable(status)
        }
        do {
            try fallback.save(data, account: account)
            return .protectedFile
        } catch {
            throw KeychainError.protectedFallback(error)
        }
    }

    func load(account: String) -> Data? {
        let result = keychain.load(service: service, account: account)
        if result.status == errSecSuccess { return result.data }
        // A build may first run without Keychain entitlement, then be re-signed.
        // The newly available Keychain has no item yet; keep the protected file
        // readable until the next successful Keychain save migrates it away.
        guard result.status == errSecItemNotFound
                || Self.isKeychainUnavailable(result.status) else { return nil }
        return try? fallback?.load(account: account)
    }

    func delete(account: String) {
        // Always attempt both stores. This is important when a build's signing
        // capabilities change between launches.
        _ = keychain.delete(service: service, account: account)
        try? fallback?.delete(account: account)
    }

    static func isKeychainUnavailable(_ status: OSStatus) -> Bool {
        status == errSecMissingEntitlement
            || status == errSecNotAvailable
            || status == errSecUnimplemented
    }

    private static func defaultFallbackDirectory() -> URL? {
        guard let applicationSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return applicationSupport.appendingPathComponent(
            "JMComicSecureState",
            isDirectory: true
        )
    }
}

private final class ProtectedFileFallback {
    private let directory: URL
    private let service: String
    private let fileManager: FileManager

    init(directory: URL, service: String, fileManager: FileManager) {
        self.directory = directory
        self.service = service
        self.fileManager = fileManager
    }

    func save(_ data: Data, account: String) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )

        let destination = fileURL(account: account)
        try data.write(
            to: destination,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: destination.path
        )
    }

    func load(account: String) throws -> Data? {
        let source = fileURL(account: account)
        guard fileManager.fileExists(atPath: source.path) else { return nil }
        return try Data(contentsOf: source, options: .mappedIfSafe)
    }

    func delete(account: String) throws {
        let destination = fileURL(account: account)
        guard fileManager.fileExists(atPath: destination.path) else { return }
        try fileManager.removeItem(at: destination)
    }

    private func fileURL(account: String) -> URL {
        // Account labels such as `session.credentials` never appear in the file
        // system. The hash is only a deterministic opaque lookup key; file contents
        // remain protected by iOS Data Protection.
        let key = Data("JMComic secure state\u{0}\(service)\u{0}\(account)".utf8)
        let digest = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(digest).bin", isDirectory: false)
    }
}
