import Foundation
import OSLog

struct AppLogger {
    static let ui = Logger(subsystem: "com.local.ai-note-taker", category: "ui")
    static let storage = Logger(subsystem: "com.local.ai-note-taker", category: "storage")
    static let transcription = Logger(subsystem: "com.local.ai-note-taker", category: "transcription")
    static let network = Logger(subsystem: "com.local.ai-note-taker", category: "network")
    static let security = Logger(subsystem: "com.local.ai-note-taker", category: "security")
    static let updates = Logger(subsystem: "com.local.ai-note-taker", category: "updates")
}
