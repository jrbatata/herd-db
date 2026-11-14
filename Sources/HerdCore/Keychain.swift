import Foundation
import Security

public protocol PasswordStore: AnyObject {
    func password(for id: UUID) -> String?
    func setPassword(_ password: String?, for id: UUID) throws
}

/// Passwords live in the login keychain, one generic-password item per connection.
public final class KeychainStore: PasswordStore {
    private let service: String

    public init(service: String = "com.juniorsilva.herd-db") {
        self.service = service
    }

    private func baseQuery(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    public func password(for id: UUID) -> String? {
        var query = baseQuery(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setPassword(_ password: String?, for id: UUID) throws {
        guard let password, !password.isEmpty else {
            let status = SecItemDelete(baseQuery(for: id) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw HerdError.keychain(status)
            }
            return
        }

        let data = Data(password.utf8)
        let query = baseQuery(for: id)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw HerdError.keychain(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw HerdError.keychain(updateStatus)
        }
    }
}
