import Foundation

enum AppPaths {
    static var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("MinuteWave", isDirectory: true)
    }

    static var databaseURL: URL {
        appSupportDirectory.appendingPathComponent("app.sqlite")
    }

    static var fluidAudioDirectory: URL {
        appSupportDirectory.appendingPathComponent("FluidAudio", isDirectory: true)
    }

    static var fluidAudioModelsDirectory: URL {
        fluidAudioDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    static var exportsDirectory: URL {
        appSupportDirectory.appendingPathComponent("Exports", isDirectory: true)
    }

    static var fluidAudioIntegrityManifestURL: URL {
        fluidAudioDirectory.appendingPathComponent("model-integrity-manifest-v1.json")
    }
}
