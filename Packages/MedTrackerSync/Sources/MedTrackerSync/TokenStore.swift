import Foundation
import Security

/// A persisted authentication session: the bearer token and the user it belongs to.
public struct StoredSession: Codable, Equatable, Sendable {
    public var token: String
    public var userId: String

    public init(token: String, userId: String) {
        self.token = token
        self.userId = userId
    }
}

/// Storage for the current `/api/v1` session. Implementations must be safe to call from any
/// isolation context (`Sendable`); `SyncEngine` (Task 15) reads/writes it around network calls.
public protocol TokenStore: Sendable {
    func load() throws -> StoredSession?
    func save(_ session: StoredSession) throws
    func clear() throws
}

/// Process-lifetime, non-persistent `TokenStore`. Useful for tests and previews. Guards its
/// state behind an `NSLock` so the class can be `Sendable` under Swift 5's `@unchecked` opt-in.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: StoredSession?

    public init() {}

    public func load() throws -> StoredSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    public func save(_ session: StoredSession) throws {
        lock.lock()
        defer { lock.unlock() }
        self.session = session
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        session = nil
    }
}

/// Keychain-backed `TokenStore`. Stores a `JSONEncoder`-encoded `StoredSession` as the
/// `kSecValueData` of a single `kSecClassGenericPassword` item identified by `service`/`account`.
///
/// Not exercised by the unit test suite (Keychain access is unreliable in headless CI), but must
/// compile and is expected to work when run inside a signed, entitled app/test host.
public struct KeychainTokenStore: TokenStore {
    private let service: String
    private let account: String

    public init(service: String = "site.jamiewhite.medtracker", account: String = "api-session") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() throws -> StoredSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainTokenStoreError.osStatus(status)
        }
        guard let data = result as? Data else {
            throw KeychainTokenStoreError.unexpectedItemFormat
        }
        return try JSONDecoder().decode(StoredSession.self, from: data)
    }

    public func save(_ session: StoredSession) throws {
        let data = try JSONEncoder().encode(session)

        // Delete any existing item first, so save() is idempotent regardless of whether a
        // session was already stored (SecItemAdd fails with errSecDuplicateItem otherwise).
        SecItemDelete(baseQuery as CFDictionary)

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainTokenStoreError.osStatus(status)
        }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainTokenStoreError.osStatus(status)
        }
    }
}

public enum KeychainTokenStoreError: Error, Equatable, Sendable {
    case osStatus(OSStatus)
    case unexpectedItemFormat
}
