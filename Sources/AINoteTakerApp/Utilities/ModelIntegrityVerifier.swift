import Foundation

struct ModelIntegrityVerifier {
    struct RepositoryInput {
        var repositoryId: String
        var rootDirectory: URL
        var expectedRelativePaths: [String]?
    }

    enum RepositoryOutcome: Equatable {
        case bootstrapped
        case verified
    }

    private struct IntegrityManifest: Codable {
        var schemaVersion: Int
        var repositories: [String: RepositoryManifest]
    }

    private struct RepositoryManifest: Codable {
        var files: [String: FileFingerprint]
        var updatedAt: Date
    }

    private struct FileFingerprint: Codable, Equatable {
        var sha256: String
        var sizeBytes: Int64
    }

    private let fileManager = FileManager.default
    private let manifestURL: URL

    init(manifestURL: URL = AppPaths.fluidAudioIntegrityManifestURL) {
        self.manifestURL = manifestURL
    }

    func verifyOrBootstrap(_ repositories: [RepositoryInput]) throws -> [String: RepositoryOutcome] {
        var manifest = try loadManifest()
        var didMutateManifest = false
        var outcomes: [String: RepositoryOutcome] = [:]

        for repository in repositories {
            let currentFiles = try fingerprintsForRepository(repository)

            if let baseline = manifest.repositories[repository.repositoryId] {
                if baseline.files != currentFiles {
                    throw AppError.providerUnavailable(
                        reason: "Model integrity mismatch detected for \(repository.repositoryId)."
                    )
                }
                outcomes[repository.repositoryId] = .verified
                continue
            }

            manifest.repositories[repository.repositoryId] = RepositoryManifest(
                files: currentFiles,
                updatedAt: Date()
            )
            didMutateManifest = true
            outcomes[repository.repositoryId] = .bootstrapped
        }

        if didMutateManifest {
            try saveManifest(manifest)
        }

        return outcomes
    }

    private func loadManifest() throws -> IntegrityManifest {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return IntegrityManifest(schemaVersion: 1, repositories: [:])
        }

        do {
            let data = try Data(contentsOf: manifestURL)
            return try JSONDecoder().decode(IntegrityManifest.self, from: data)
        } catch {
            throw AppError.storageFailure(
                reason: "Model integrity baseline is unreadable. Delete the integrity manifest to re-bootstrap."
            )
        }
    }

    private func saveManifest(_ manifest: IntegrityManifest) throws {
        try fileManager.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    private func fingerprintsForRepository(_ repository: RepositoryInput) throws -> [String: FileFingerprint] {
        guard fileManager.fileExists(atPath: repository.rootDirectory.path) else {
            throw AppError.providerUnavailable(reason: "Model repository directory is missing for \(repository.repositoryId).")
        }

        let relativePaths: [String]
        if let expected = repository.expectedRelativePaths, !expected.isEmpty {
            relativePaths = expected.sorted()
        } else {
            relativePaths = try enumerateRelativeFilePaths(in: repository.rootDirectory)
        }

        guard !relativePaths.isEmpty else {
            throw AppError.providerUnavailable(reason: "No model files found for \(repository.repositoryId).")
        }

        var result: [String: FileFingerprint] = [:]
        for relativePath in relativePaths {
            let fileURL = try safeRepositoryFileURL(rootDirectory: repository.rootDirectory, relativePath: relativePath)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                throw AppError.providerUnavailable(reason: "Model file missing: \(repository.repositoryId)/\(relativePath)")
            }
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            guard let sizeNumber = attributes[.size] as? NSNumber else {
                throw AppError.storageFailure(reason: "Unable to read model file size for \(relativePath).")
            }
            let sha = try SHA256Hasher.hash(fileURL: fileURL)
            result[relativePath] = FileFingerprint(
                sha256: sha,
                sizeBytes: sizeNumber.int64Value
            )
        }
        return result
    }

    private func enumerateRelativeFilePaths(in rootDirectory: URL) throws -> [String] {
        guard let enumerator = fileManager.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var paths: [String] = []
        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues.isRegularFile == true else { continue }
            let relative = fileURL.path.replacingOccurrences(
                of: rootDirectory.path.hasSuffix("/") ? rootDirectory.path : rootDirectory.path + "/",
                with: ""
            )
            if relative.isEmpty == false {
                paths.append(relative)
            }
        }
        return paths.sorted()
    }

    private func safeRepositoryFileURL(rootDirectory: URL, relativePath: String) throws -> URL {
        guard relativePath.contains("..") == false else {
            throw AppError.providerUnavailable(reason: "Invalid model path detected while verifying integrity.")
        }

        let root = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()

        if candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") {
            return candidate
        }
        throw AppError.providerUnavailable(reason: "Model integrity check rejected unsafe file path.")
    }
}
