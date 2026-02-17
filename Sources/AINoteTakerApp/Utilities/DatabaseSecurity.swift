import Foundation
import SQLite3
import Security

enum DatabaseEncryptionMode {
    case disabled
    case sqlcipher(keyHex: String)
}

enum DatabaseFileFormat: Equatable {
    case missing
    case plaintextSQLite
    case nonSQLite
}

struct DatabaseFormatInspector {
    static func inspect(at databaseURL: URL) -> DatabaseFileFormat {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return .missing
        }

        let headerLength = 16
        guard let handle = try? FileHandle(forReadingFrom: databaseURL) else {
            return .nonSQLite
        }
        defer {
            try? handle.close()
        }

        let data = (try? handle.read(upToCount: headerLength)) ?? Data()
        if data.count < headerLength {
            return .nonSQLite
        }

        let sqliteHeader = Data("SQLite format 3\0".utf8)
        if data == sqliteHeader {
            return .plaintextSQLite
        }
        return .nonSQLite
    }
}

struct DatabaseEncryptionStateStore {
    private struct Payload: Codable {
        var encryptionEnabled: Bool
    }

    private let customConfigURL: URL?

    init(configURL: URL? = nil) {
        self.customConfigURL = configURL
    }

    private var configURL: URL {
        if let customConfigURL {
            return customConfigURL
        }
        return AppPaths.appSupportDirectory.appendingPathComponent("database-security.json")
    }

    func load(defaultValue: Bool = false) -> Bool {
        guard let data = try? Data(contentsOf: configURL) else {
            return defaultValue
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return defaultValue
        }
        return payload.encryptionEnabled
    }

    func save(encryptionEnabled: Bool) throws {
        try FileManager.default.createDirectory(at: AppPaths.appSupportDirectory, withIntermediateDirectories: true)
        let payload = Payload(encryptionEnabled: encryptionEnabled)
        let data = try JSONEncoder().encode(payload)
        try data.write(to: configURL, options: .atomic)
    }
}

struct SQLCipherSupport {
    static func runtimeIsAvailable() -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open(":memory:", &db) == SQLITE_OK, let db else {
            return false
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA cipher_version;", -1, &statement, nil) == SQLITE_OK, let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return false
        }
        guard let cString = sqlite3_column_text(statement, 0) else {
            return false
        }

        let version = String(cString: cString).trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty == false
    }
}

enum SQLCipherMigrationDirection {
    case plaintextToEncrypted
    case encryptedToPlaintext
}

struct SQLCipherMigrator {
    static func migrateDatabase(
        at databaseURL: URL,
        direction: SQLCipherMigrationDirection,
        keyHex: String
    ) throws {
        let key = sanitizedHexKey(keyHex)
        guard !key.isEmpty else {
            throw AppError.storageFailure(reason: "Database migration key is empty.")
        }

        let fm = FileManager.default
        let tempURL = databaseURL.deletingLastPathComponent()
            .appendingPathComponent(databaseURL.lastPathComponent + ".migration.tmp")
        let backupURL = databaseURL.deletingLastPathComponent()
            .appendingPathComponent(databaseURL.lastPathComponent + ".migration.backup")

        try removeIfExists(tempURL, fileManager: fm)
        try removeIfExists(backupURL, fileManager: fm)

        try withDatabase(databaseURL: databaseURL) { db in
            switch direction {
            case .plaintextToEncrypted:
                try exec(db, sql: "PRAGMA wal_checkpoint(TRUNCATE);")
                let attach = "ATTACH DATABASE '\(escapeSQL(databaseURL: tempURL))' AS encrypted KEY \"x'\(key)'\";"
                try exec(db, sql: attach)
                try exec(db, sql: "SELECT sqlcipher_export('encrypted');")
                try exec(db, sql: "DETACH DATABASE encrypted;")

            case .encryptedToPlaintext:
                try exec(db, sql: "PRAGMA key = \"x'\(key)'\";")
                // Verify the key before export.
                try exec(db, sql: "SELECT count(*) FROM sqlite_master;")
                let attach = "ATTACH DATABASE '\(escapeSQL(databaseURL: tempURL))' AS plaintext KEY '';"
                try exec(db, sql: attach)
                try exec(db, sql: "SELECT sqlcipher_export('plaintext');")
                try exec(db, sql: "DETACH DATABASE plaintext;")
            }
        }

        cleanupSQLiteSidecars(for: databaseURL, fileManager: fm)
        cleanupSQLiteSidecars(for: tempURL, fileManager: fm)

        do {
            if fm.fileExists(atPath: databaseURL.path) {
                try fm.moveItem(at: databaseURL, to: backupURL)
            }
            try fm.moveItem(at: tempURL, to: databaseURL)
            try removeIfExists(backupURL, fileManager: fm)
        } catch {
            if fm.fileExists(atPath: databaseURL.path) == false && fm.fileExists(atPath: backupURL.path) {
                try? fm.moveItem(at: backupURL, to: databaseURL)
            }
            throw AppError.storageFailure(reason: "Database migration failed: \(error.localizedDescription)")
        }
    }

    private static func withDatabase(
        databaseURL: URL,
        body: (OpaquePointer) throws -> Void
    ) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw AppError.storageFailure(reason: "Unable to open database for migration: \(databaseURL.path)")
        }
        defer { sqlite3_close(handle) }

        try body(handle)
    }

    private static func exec(_ db: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown sqlite error"
            sqlite3_free(errorMessage)
            throw AppError.storageFailure(reason: message)
        }
    }

    private static func cleanupSQLiteSidecars(for databaseURL: URL, fileManager: FileManager) {
        let wal = URL(fileURLWithPath: databaseURL.path + "-wal")
        let shm = URL(fileURLWithPath: databaseURL.path + "-shm")
        try? removeIfExists(wal, fileManager: fileManager)
        try? removeIfExists(shm, fileManager: fileManager)
    }

    private static func removeIfExists(_ url: URL, fileManager: FileManager) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private static func sanitizedHexKey(_ keyHex: String) -> String {
        keyHex.lowercased().filter { $0.isHexDigit }
    }

    private static func escapeSQL(databaseURL: URL) -> String {
        databaseURL.path.replacingOccurrences(of: "'", with: "''")
    }
}

struct DatabaseKeyBootstrapper {
    private let keychain = KeychainStore()
    private let keyRef = "minutewave-database-key-v1"

    func ensureKeyHex() throws -> String {
        if let existing = try keychain.get(keyRef), existing.isEmpty == false {
            return existing
        }

        let random = try generateRandomBytes(count: 48)
        let hex = random.map { String(format: "%02x", $0) }.joined()
        try keychain.set(hex, key: keyRef)
        return hex
    }

    private func generateRandomBytes(count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw AppError.storageFailure(reason: "Unable to generate database encryption key (\(status)).")
        }
        return bytes
    }
}
