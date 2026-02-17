import Foundation
import Security

struct KeychainStore {
    private static let service = "com.vepando.minutewave"
    private static let legacyServices = ["com.local.ai-note-taker"]
    private static let cacheLock = NSLock()
    private static var inMemoryCache: [String: String] = [:]
    private static var attemptedLegacyMigrationKeys: Set<String> = []

    private func cacheKey(_ key: String, service: String = service) -> String {
        "\(service)::\(key)"
    }

    private func setCached(_ value: String?, key: String, service: String = service) {
        Self.cacheLock.lock()
        defer { Self.cacheLock.unlock() }
        let cacheKey = cacheKey(key, service: service)
        if let value {
            Self.inMemoryCache[cacheKey] = value
        } else {
            Self.inMemoryCache.removeValue(forKey: cacheKey)
        }
    }

    private func cachedValue(for key: String, service: String = service) -> String? {
        Self.cacheLock.lock()
        defer { Self.cacheLock.unlock() }
        return Self.inMemoryCache[cacheKey(key, service: service)]
    }

    private func markLegacyMigrationAttempted(for key: String) {
        Self.cacheLock.lock()
        defer { Self.cacheLock.unlock() }
        Self.attemptedLegacyMigrationKeys.insert(key)
    }

    private func hasAttemptedLegacyMigration(for key: String) -> Bool {
        Self.cacheLock.lock()
        defer { Self.cacheLock.unlock() }
        return Self.attemptedLegacyMigrationKeys.contains(key)
    }

    func set(_ value: String, key: String) throws {
        let encoded = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: encoded
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = encoded
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw AppError.storageFailure(reason: "Keychain save failed with status \(addStatus).")
            }
            setCached(value, key: key)
            return
        }

        guard status == errSecSuccess else {
            throw AppError.storageFailure(reason: "Keychain update failed with status \(status).")
        }
        setCached(value, key: key)
    }

    func get(_ key: String) throws -> String? {
        if let cached = cachedValue(for: key) {
            return cached
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess {
            guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
                return nil
            }
            setCached(string, key: key)
            return string
        }
        if status != errSecItemNotFound {
            throw AppError.storageFailure(reason: "Keychain read failed with status \(status).")
        }

        // Best-effort one-time migration from legacy service namespace.
        if hasAttemptedLegacyMigration(for: key) {
            return nil
        }
        markLegacyMigrationAttempted(for: key)
        for legacy in Self.legacyServices {
            guard legacy != Self.service else { continue }
            if let migrated = try readValue(key: key, service: legacy) {
                try set(migrated, key: key)
                try? delete(key, service: legacy)
                return migrated
            }
        }

        return nil
    }

    private func readValue(key: String, service: String) throws -> String? {
        if let cached = cachedValue(for: key, service: service) {
            return cached
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw AppError.storageFailure(reason: "Keychain read failed with status \(status).")
        }
        guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        setCached(string, key: key, service: service)
        return string
    }

    func delete(_ key: String) throws {
        try delete(key, service: Self.service)
        setCached(nil, key: key)
        for legacy in Self.legacyServices where legacy != Self.service {
            try? delete(key, service: legacy)
            setCached(nil, key: key, service: legacy)
        }
    }

    private func delete(_ key: String, service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.storageFailure(reason: "Keychain delete failed with status \(status).")
        }
    }
}
