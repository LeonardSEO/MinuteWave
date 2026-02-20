import Foundation

@MainActor
final class AppContainer {
    let repository: SessionRepository
    let keychain: KeychainStore
    let audioEngine: AudioCaptureEngine
    let localProvider: LocalFluidAudioProvider
    let azureProvider: AzureTranscriptionProvider
    let openAIProvider: OpenAITranscriptionProvider

    static let shared: AppContainer = {
        do {
            return try AppContainer()
        } catch {
            fatalError("Failed to initialize app container: \(error.localizedDescription)")
        }
    }()

    private init() throws {
        try FileManager.default.createDirectory(at: AppPaths.appSupportDirectory, withIntermediateDirectories: true)

        let registryResolution = ModelRegistryPolicy.applyGlobalPolicy()
        if let warning = registryResolution.warning {
            AppLogger.security.warning("\(warning, privacy: .public)")
        }

        let encryptionStore = DatabaseEncryptionStateStore()
        var encryptionEnabled = encryptionStore.load(defaultValue: true)
        let sqlCipherAvailable = SQLCipherSupport.runtimeIsAvailable()
        let databaseFormat = DatabaseFormatInspector.inspect(at: AppPaths.databaseURL)
        var encryptionMode: DatabaseEncryptionMode = .disabled

        if encryptionEnabled {
            if sqlCipherAvailable {
                let key = try DatabaseKeyBootstrapper().ensureKeyHex()
                if databaseFormat == .plaintextSQLite {
                    try SQLCipherMigrator.migrateDatabase(
                        at: AppPaths.databaseURL,
                        direction: .plaintextToEncrypted,
                        keyHex: key
                    )
                }
                encryptionMode = .sqlcipher(keyHex: key)
            } else {
                if databaseFormat == .nonSQLite {
                    throw AppError.storageFailure(
                        reason: "Database appears encrypted, but SQLCipher runtime is unavailable on this system."
                    )
                }
                encryptionEnabled = false
                try? encryptionStore.save(encryptionEnabled: false)
                AppLogger.security.error(
                    "SQLCipher runtime unavailable at startup; falling back to plaintext storage and forcing encryptionEnabled=false."
                )
            }
        } else if databaseFormat == .nonSQLite {
            guard sqlCipherAvailable else {
                throw AppError.storageFailure(
                    reason: "Encrypted database detected while encryption is disabled, and SQLCipher runtime is unavailable."
                )
            }
            let key = try DatabaseKeyBootstrapper().ensureKeyHex()
            try SQLCipherMigrator.migrateDatabase(
                at: AppPaths.databaseURL,
                direction: .encryptedToPlaintext,
                keyHex: key
            )
        }

        self.repository = try SQLiteRepository(databaseURL: AppPaths.databaseURL, encryptionMode: encryptionMode)
        self.keychain = KeychainStore()
        self.audioEngine = HybridAudioCaptureEngine()
        self.localProvider = LocalFluidAudioProvider()
        self.azureProvider = AzureTranscriptionProvider()
        self.openAIProvider = OpenAITranscriptionProvider()
    }
}
