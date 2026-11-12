import Foundation
import Security
import CryptoKit

/// One Keychain value contains the whole pair; updating it is atomic. Nothing is stored in defaults.
public protocol TokenStorage: Sendable {
    func load() throws -> TokenPair?
    func store(_ pair: TokenPair?) throws
}

/// The staff step-up grant: its own token pair, fixed to one makerspace (PRD §7 item 6).
public struct StaffGrantRecord: Sendable, Equatable, Codable {
    public let pair: TokenPair
    public let makerspaceID: Int
    public let makerspaceSlug: String
    public init(pair: TokenPair, makerspaceID: Int, makerspaceSlug: String) {
        self.pair = pair; self.makerspaceID = makerspaceID; self.makerspaceSlug = makerspaceSlug
    }
}

public protocol StaffGrantStorage: Sendable {
    func load() throws -> StaffGrantRecord?
    func store(_ record: StaffGrantRecord?) throws
}

/// The server's remembered-device value (`device_trust`), echoed as `X-Device-Trust` on sign-ins.
public protocol DeviceTrustStorage: Sendable {
    func load() throws -> String?
    func store(_ value: String?) throws
}

/// One generic-password item per deployment origin and purpose, this device only.
struct KeychainItem: Sendable {
    private let account: String
    private let service: String
    init(origin: ServerOrigin, service: String) {
        account = SHA256.hash(data: Data(origin.url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        self.service = service
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    func load() throws -> Data? {
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw vaultError }
        return data
    }
    func store(_ value: Data?) throws {
        guard let value else {
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecItemNotFound { try check(status) }
            return
        }
        let changes: [String: Any] = [kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            try check(SecItemAdd(query.merging(changes) { _, new in new } as CFDictionary, nil))
        } else { try check(status) }
    }
    private var vaultError: APIError {
        APIError(status: 0, code: "secure_storage_unavailable", detail: "Secure storage is unavailable. Unlock your device and try again.")
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw APIError(status: 0, code: "secure_storage_unavailable_\(status)", detail: vaultError.detail)
        }
    }
}

public struct TokenVault: TokenStorage {
    private let item: KeychainItem
    public init(origin: ServerOrigin, service: String = "org.spaceworks.device-session") {
        item = KeychainItem(origin: origin, service: service)
    }
    public func load() throws -> TokenPair? {
        try item.load().map { try JSONDecoder().decode(TokenPair.self, from: $0) }
    }
    public func store(_ pair: TokenPair?) throws { try item.store(pair.map { try JSONEncoder().encode($0) }) }
}

public struct StaffGrantVault: StaffGrantStorage {
    private let item: KeychainItem
    public init(origin: ServerOrigin, service: String = "org.spaceworks.staff-session") {
        item = KeychainItem(origin: origin, service: service)
    }
    public func load() throws -> StaffGrantRecord? {
        try item.load().map { try JSONDecoder().decode(StaffGrantRecord.self, from: $0) }
    }
    public func store(_ record: StaffGrantRecord?) throws { try item.store(record.map { try JSONEncoder().encode($0) }) }
}

public struct DeviceTrustVault: DeviceTrustStorage {
    private let item: KeychainItem
    public init(origin: ServerOrigin, service: String = "org.spaceworks.device-trust") {
        item = KeychainItem(origin: origin, service: service)
    }
    public func load() throws -> String? { try item.load().flatMap { String(data: $0, encoding: .utf8) } }
    public func store(_ value: String?) throws { try item.store(value.map { Data($0.utf8) }) }
}

/// In-memory storage for previews, the isolated demo and tests that inject their own token storage.
public final class MemoryStaffGrantStorage: StaffGrantStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var record: StaffGrantRecord?
    public init(_ record: StaffGrantRecord? = nil) { self.record = record }
    public func load() throws -> StaffGrantRecord? { lock.withLock { record } }
    public func store(_ record: StaffGrantRecord?) throws { lock.withLock { self.record = record } }
}

public final class MemoryDeviceTrustStorage: DeviceTrustStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    public init(_ value: String? = nil) { self.value = value }
    public func load() throws -> String? { lock.withLock { value } }
    public func store(_ value: String?) throws { lock.withLock { self.value = value } }
}
