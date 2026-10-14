import Foundation
import Security

/// A non-secret, per-installation identifier. It is intentionally separate from
/// a push token: push tokens can rotate, while the server uses this value to
/// recognise one physical installation across authenticated sessions.
final class AloDeviceIdentity {
    static let shared = AloDeviceIdentity()

    private let service = "com.alo.ios.device-identity.v1"
    private let account = "installation-id"
    private let legacyDefaultsKey = "alo.ios.push.device-id.v1"
    private let identifierStorage: String

    private init() {
        if let stored = Self.read(service: service, account: account),
           let identifier = String(data: stored, encoding: .utf8),
           identifier.count >= 16 {
            identifierStorage = identifier
            return
        }

        let migrated = UserDefaults.standard.string(forKey: legacyDefaultsKey)
        let identifier = (migrated?.count ?? 0) >= 16
            ? migrated!
            : UUID().uuidString.lowercased()
        Self.store(Data(identifier.utf8), service: service, account: account)
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        identifierStorage = identifier
    }

    var identifier: String { identifierStorage }

    private static func read(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    private static func store(_ data: Data, service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard update == errSecItemNotFound else { return }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        _ = SecItemAdd(attributes as CFDictionary, nil)
    }
}

struct AloStoredAccount: Identifiable, Codable, Equatable {
    let userId: Int
    let name: String
    let username: String
    let avatarURL: String
    let updatedAt: Date

    var id: Int { userId }

    init(user: AloCurrentUser, updatedAt: Date = Date()) {
        userId = user.id
        name = user.name
        username = user.username
        avatarURL = user.avatarUrl
        self.updatedAt = updatedAt
    }
}

enum AloAccountSessionStoreError: LocalizedError {
    case missingSession
    case serializationFailed
    case keychainFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingSession:
            return "Сохранённый сеанс больше недоступен. Войдите в аккаунт снова."
        case .serializationFailed:
            return "Не удалось безопасно сохранить сеанс."
        case let .keychainFailure(status):
            return "Не удалось записать защищённый сеанс (код \(status))."
        }
    }
}

/// Stores only the server-issued session cookies in Keychain. Account metadata is
/// deliberately kept separately in UserDefaults so no password or cookie value
/// can be read from regular app storage.
@MainActor
final class AloAccountSessionStore {
    static let shared = AloAccountSessionStore()

    private let metadataKey = "alo.ios.account-metadata.v1"
    private let keychainService = "com.alo.ios.account-sessions.v1"

    private init() {}

    var accounts: [AloStoredAccount] {
        guard let data = UserDefaults.standard.data(forKey: metadataKey),
              let decoded = try? JSONDecoder().decode([AloStoredAccount].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(user: AloCurrentUser, cookies: [HTTPCookie]) throws {
        guard !cookies.isEmpty else { throw AloAccountSessionStoreError.missingSession }
        let sessionData = try serialize(cookies)
        try storeKeychain(sessionData, account: sessionAccount(for: user.id))

        var updated = accounts.filter { $0.userId != user.id }
        updated.append(AloStoredAccount(user: user))
        persistMetadata(updated)
    }

    func cookies(for account: AloStoredAccount) throws -> [HTTPCookie] {
        guard let data = readKeychain(account: sessionAccount(for: account.userId)) else {
            throw AloAccountSessionStoreError.missingSession
        }
        let cookies = try deserialize(data)
        guard !cookies.isEmpty else { throw AloAccountSessionStoreError.missingSession }
        return cookies
    }

    func remove(userId: Int) {
        deleteKeychain(account: sessionAccount(for: userId))
        persistMetadata(accounts.filter { $0.userId != userId })
    }

    func removeAll() {
        for account in accounts {
            deleteKeychain(account: sessionAccount(for: account.userId))
        }
        UserDefaults.standard.removeObject(forKey: metadataKey)
    }

    private func persistMetadata(_ accounts: [AloStoredAccount]) {
        let unique = Dictionary(grouping: accounts, by: \.userId).compactMap { _, values in
            values.max(by: { $0.updatedAt < $1.updatedAt })
        }
        let sorted = unique.sorted { $0.updatedAt > $1.updatedAt }
        guard let data = try? JSONEncoder().encode(sorted) else { return }
        UserDefaults.standard.set(data, forKey: metadataKey)
    }

    private func sessionAccount(for userId: Int) -> String {
        "session.\(userId)"
    }

    private func serialize(_ cookies: [HTTPCookie]) throws -> Data {
        let propertyLists = cookies.compactMap { cookie -> [String: Any]? in
            guard let properties = cookie.properties else { return nil }
            let allowedKeys: Set<String> = [
                HTTPCookiePropertyKey.name.rawValue,
                HTTPCookiePropertyKey.value.rawValue,
                HTTPCookiePropertyKey.domain.rawValue,
                HTTPCookiePropertyKey.path.rawValue,
                HTTPCookiePropertyKey.expires.rawValue,
                HTTPCookiePropertyKey.secure.rawValue,
                "HttpOnly",
                HTTPCookiePropertyKey.version.rawValue,
                HTTPCookiePropertyKey.maximumAge.rawValue,
                HTTPCookiePropertyKey.comment.rawValue,
                HTTPCookiePropertyKey.commentURL.rawValue
            ]
            let values = properties.reduce(into: [String: Any]()) { result, item in
                guard allowedKeys.contains(item.key.rawValue) else { return }
                if let url = item.value as? URL {
                    result[item.key.rawValue] = url.absoluteString
                } else {
                    result[item.key.rawValue] = item.value
                }
            }
            let cookieProperties = Dictionary(uniqueKeysWithValues: values.map {
                (HTTPCookiePropertyKey(rawValue: $0.key), $0.value)
            })
            return HTTPCookie(properties: cookieProperties) == nil
                ? nil
                : values
        }
        guard !propertyLists.isEmpty,
              PropertyListSerialization.propertyList(propertyLists, isValidFor: .binary) else {
            throw AloAccountSessionStoreError.serializationFailed
        }
        return try PropertyListSerialization.data(
            fromPropertyList: propertyLists,
            format: .binary,
            options: 0
        )
    }

    private func deserialize(_ data: Data) throws -> [HTTPCookie] {
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let rows = plist as? [[String: Any]] else {
            throw AloAccountSessionStoreError.serializationFailed
        }
        return rows.compactMap { row in
            let properties = Dictionary(uniqueKeysWithValues: row.map {
                (HTTPCookiePropertyKey(rawValue: $0.key), $0.value)
            })
            return HTTPCookie(properties: properties)
        }
    }

    private func readKeychain(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    private func storeKeychain(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        let update = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            throw AloAccountSessionStoreError.keychainFailure(update)
        }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AloAccountSessionStoreError.keychainFailure(status)
        }
    }

    private func deleteKeychain(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
