import Foundation
import OSLog

struct AppLogger {
    static let ui = Logger(subsystem: "com.vepando.minutewave", category: "ui")
    static let storage = Logger(subsystem: "com.vepando.minutewave", category: "storage")
    static let transcription = Logger(subsystem: "com.vepando.minutewave", category: "transcription")
    static let network = Logger(subsystem: "com.vepando.minutewave", category: "network")
    static let security = Logger(subsystem: "com.vepando.minutewave", category: "security")
}
