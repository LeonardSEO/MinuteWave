import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteRepository: SessionRepository, @unchecked Sendable {
    private enum SQLiteValue {
        case int64(Int64)
        case double(Double)
        case text(String)
        case blob(Data)
        case null
    }

    private let db: OpaquePointer
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let queue = DispatchQueue(label: "ai.note.taker.sqlite")

    init(databaseURL: URL, encryptionMode: DatabaseEncryptionMode = .disabled) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(databaseURL.path, &handle, flags, nil) != SQLITE_OK || handle == nil {
            throw AppError.storageFailure(reason: "Unable to open sqlite database at \(databaseURL.path)")
        }
        db = handle!

        try queue.sync {
            try applyEncryptionMode(encryptionMode)
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA foreign_keys=ON;")
            try createSchema()
            try bootstrapDefaultSettingsIfNeeded()
        }
    }

    deinit {
        _ = queue.sync {
            sqlite3_close(db)
        }
    }

    func createSession(name: String, provider: TranscriptionProviderType) async throws -> SessionRecord {
        try queue.sync {
            let session = SessionRecord(
                id: UUID(),
                name: name,
                startedAt: Date(),
                endedAt: nil,
                status: .idle,
                transcriptionProvider: provider,
                summaryStatus: .notStarted
            )

            try execute(
                """
                INSERT INTO sessions (id, name, started_at, ended_at, status, transcription_provider, summary_status)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(session.id.uuidString),
                    .text(session.name),
                    .double(session.startedAt.timeIntervalSince1970),
                    .null,
                    .text(session.status.rawValue),
                    .text(session.transcriptionProvider.rawValue),
                    .text(session.summaryStatus.rawValue)
                ]
            )

            try execute(
                "INSERT INTO chat_threads (id, session_id, created_at) VALUES (?, ?, ?)",
                bindings: [.text(UUID().uuidString), .text(session.id.uuidString), .double(Date().timeIntervalSince1970)]
            )

            return session
        }
    }

    func updateSessionStatus(sessionId: UUID, status: SessionStatus, endedAt: Date?) async throws {
        try queue.sync {
            try execute(
                "UPDATE sessions SET status = ?, ended_at = COALESCE(?, ended_at) WHERE id = ?",
                bindings: [
                    .text(status.rawValue),
                    endedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                    .text(sessionId.uuidString)
                ]
            )
        }
    }

    func updateSessionName(sessionId: UUID, name: String) async throws {
        try queue.sync {
            try execute(
                "UPDATE sessions SET name = ? WHERE id = ?",
                bindings: [
                    .text(name),
                    .text(sessionId.uuidString)
                ]
            )
        }
    }

    func listSessions(search: String) async throws -> [SessionRecord] {
        try queue.sync {
            let filter = "%\(search)%"
            let rows = try query(
                """
                SELECT id, name, started_at, ended_at, status, transcription_provider, summary_status
                FROM sessions
                WHERE name LIKE ?
                ORDER BY started_at DESC
                """,
                bindings: [.text(filter)]
            )

            return try rows.map(decodeSession)
        }
    }

    func getSession(id: UUID) async throws -> SessionRecord? {
        try queue.sync {
            let rows = try query(
                """
                SELECT id, name, started_at, ended_at, status, transcription_provider, summary_status
                FROM sessions WHERE id = ?
                """,
                bindings: [.text(id.uuidString)]
            )
            return try rows.first.map(decodeSession)
        }
    }

    func insertSegment(_ segment: TranscriptSegment) async throws {
        try queue.sync {
            try execute(
                """
                INSERT OR REPLACE INTO transcript_segments
                (id, session_id, start_ms, end_ms, text, confidence, source_provider, is_final, speaker_label)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(segment.id.uuidString),
                    .text(segment.sessionId.uuidString),
                    .int64(segment.startMs),
                    .int64(segment.endMs),
                    .text(segment.text),
                    .double(segment.confidence),
                    .text(segment.sourceProvider.rawValue),
                    .int64(segment.isFinal ? 1 : 0),
                    segment.speakerLabel.map(SQLiteValue.text) ?? .null
                ]
            )
        }
    }

    func listSegments(sessionId: UUID) async throws -> [TranscriptSegment] {
        try queue.sync {
            let rows = try query(
                """
                SELECT id, session_id, start_ms, end_ms, text, confidence, source_provider, is_final, speaker_label
                FROM transcript_segments
                WHERE session_id = ?
                ORDER BY start_ms ASC
                """,
                bindings: [.text(sessionId.uuidString)]
            )

            return try rows.map { row in
                guard
                    let id = UUID(uuidString: row["id"] as? String ?? ""),
                    let sessionUUID = UUID(uuidString: row["session_id"] as? String ?? ""),
                    let providerRaw = row["source_provider"] as? String,
                    let provider = TranscriptionProviderType(rawValue: providerRaw)
                else {
                    throw AppError.storageFailure(reason: "Unable to decode transcript segment row")
                }

                return TranscriptSegment(
                    id: id,
                    sessionId: sessionUUID,
                    startMs: row["start_ms"] as? Int64 ?? 0,
                    endMs: row["end_ms"] as? Int64 ?? 0,
                    text: row["text"] as? String ?? "",
                    confidence: row["confidence"] as? Double ?? 0,
                    sourceProvider: provider,
                    isFinal: (row["is_final"] as? Int64 ?? 0) == 1,
                    speakerLabel: row["speaker_label"] as? String
                )
            }
        }
    }

    func upsertTranscriptChunks(sessionId: UUID, chunks: [String]) async throws {
        try queue.sync {
            try execute("DELETE FROM transcript_chunks WHERE session_id = ?", bindings: [.text(sessionId.uuidString)])

            for (index, chunk) in chunks.enumerated() {
                try execute(
                    "INSERT INTO transcript_chunks (session_id, chunk_index, chunk_text) VALUES (?, ?, ?)",
                    bindings: [.text(sessionId.uuidString), .int64(Int64(index)), .text(chunk)]
                )
            }
        }
    }

    func saveSummary(sessionId: UUID, summary: MeetingSummary) async throws {
        try queue.sync {
            let rows = try query("SELECT COALESCE(MAX(version), 0) AS max_version FROM summaries WHERE session_id = ?", bindings: [.text(sessionId.uuidString)])
            let current = rows.first?["max_version"] as? Int64 ?? 0
            let nextVersion = Int(current) + 1

            var updated = summary
            updated.version = nextVersion
            let payload = try encoder.encode(updated)

            try execute(
                "INSERT INTO summaries (session_id, version, payload_json, generated_at) VALUES (?, ?, ?, ?)",
                bindings: [
                    .text(sessionId.uuidString),
                    .int64(Int64(nextVersion)),
                    .blob(payload),
                    .double(Date().timeIntervalSince1970)
                ]
            )

            try execute(
                "UPDATE sessions SET summary_status = ? WHERE id = ?",
                bindings: [.text(SummaryStatus.completed.rawValue), .text(sessionId.uuidString)]
            )
        }
    }

    func latestSummary(sessionId: UUID) async throws -> MeetingSummary? {
        try queue.sync {
            let rows = try query(
                """
                SELECT payload_json FROM summaries
                WHERE session_id = ?
                ORDER BY version DESC
                LIMIT 1
                """,
                bindings: [.text(sessionId.uuidString)]
            )

            guard let payload = rows.first?["payload_json"] as? Data else {
                return nil
            }
            return try decoder.decode(MeetingSummary.self, from: payload)
        }
    }

    func appendChatMessage(_ message: ChatMessage) async throws {
        try queue.sync {
            let citations = try encoder.encode(message.citations)
            try execute(
                """
                INSERT OR IGNORE INTO chat_threads (id, session_id, created_at)
                VALUES (?, ?, ?)
                """,
                bindings: [
                    .text(message.threadId.uuidString),
                    .text(message.sessionId.uuidString),
                    .double(message.createdAt.timeIntervalSince1970)
                ]
            )
            try execute(
                """
                INSERT INTO chat_messages (id, thread_id, session_id, role, text, citations_json, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(message.id.uuidString),
                    .text(message.threadId.uuidString),
                    .text(message.sessionId.uuidString),
                    .text(message.role.rawValue),
                    .text(message.text),
                    .blob(citations),
                    .double(message.createdAt.timeIntervalSince1970)
                ]
            )
        }
    }

    func listChatMessages(sessionId: UUID) async throws -> [ChatMessage] {
        try queue.sync {
            let rows = try query(
                """
                SELECT id, thread_id, session_id, role, text, citations_json, created_at
                FROM chat_messages WHERE session_id = ? ORDER BY created_at ASC
                """,
                bindings: [.text(sessionId.uuidString)]
            )

            return try rows.map { row in
                guard
                    let id = UUID(uuidString: row["id"] as? String ?? ""),
                    let threadId = UUID(uuidString: row["thread_id"] as? String ?? ""),
                    let sessionUUID = UUID(uuidString: row["session_id"] as? String ?? ""),
                    let roleRaw = row["role"] as? String,
                    let role = ChatMessage.Role(rawValue: roleRaw)
                else {
                    throw AppError.storageFailure(reason: "Unable to decode chat message row")
                }

                let citationsData = row["citations_json"] as? Data ?? Data("[]".utf8)
                let citations = try decoder.decode([TranscriptCitation].self, from: citationsData)

                return ChatMessage(
                    id: id,
                    threadId: threadId,
                    sessionId: sessionUUID,
                    role: role,
                    text: row["text"] as? String ?? "",
                    citations: citations,
                    createdAt: Date(timeIntervalSince1970: row["created_at"] as? Double ?? 0)
                )
            }
        }
    }

    func saveSettings(_ settings: AppSettings) async throws {
        try queue.sync {
            let payload = try encoder.encode(settings)
            try execute(
                "INSERT OR REPLACE INTO settings (id, payload_json) VALUES (1, ?)",
                bindings: [.blob(payload)]
            )
        }
    }

    func loadSettings() async throws -> AppSettings {
        try queue.sync {
            let rows = try query("SELECT payload_json FROM settings WHERE id = 1")
            guard let payload = rows.first?["payload_json"] as? Data else {
                return .default
            }
            return (try? decoder.decode(AppSettings.self, from: payload)) ?? .default
        }
    }

    func saveModelInstallState(_ state: ModelInstallationState) async throws {
        try queue.sync {
            try execute(
                """
                INSERT OR REPLACE INTO model_installations
                (model_id, status, progress, local_path, last_error, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(state.modelId),
                    .text(state.status.rawValue),
                    .double(state.progress),
                    state.localPath.map(SQLiteValue.text) ?? .null,
                    state.lastError.map(SQLiteValue.text) ?? .null,
                    .double(Date().timeIntervalSince1970)
                ]
            )
        }
    }

    func loadModelInstallState(modelId: String) async throws -> ModelInstallationState? {
        try queue.sync {
            let rows = try query(
                "SELECT model_id, status, progress, local_path, last_error FROM model_installations WHERE model_id = ?",
                bindings: [.text(modelId)]
            )

            guard let row = rows.first,
                  let statusRaw = row["status"] as? String,
                  let status = ModelInstallStatus(rawValue: statusRaw),
                  let model = row["model_id"] as? String else {
                return nil
            }

            return ModelInstallationState(
                modelId: model,
                status: status,
                progress: row["progress"] as? Double ?? 0,
                localPath: row["local_path"] as? String,
                lastError: row["last_error"] as? String
            )
        }
    }

    func addAuditEvent(category: String, message: String) async throws {
        try queue.sync {
            try execute(
                "INSERT INTO audit_events (category, message, created_at) VALUES (?, ?, ?)",
                bindings: [.text(category), .text(message), .double(Date().timeIntervalSince1970)]
            )
        }
    }

    private func bootstrapDefaultSettingsIfNeeded() throws {
        let rows = try query("SELECT COUNT(*) AS count FROM settings WHERE id = 1")
        let count = rows.first?["count"] as? Int64 ?? 0
        guard count == 0 else {
            return
        }

        let payload = try encoder.encode(AppSettings.default)
        try execute("INSERT INTO settings (id, payload_json) VALUES (1, ?)", bindings: [.blob(payload)])
    }

    private func applyEncryptionMode(_ mode: DatabaseEncryptionMode) throws {
        switch mode {
        case .disabled:
            return
        case .sqlcipher(let keyHex):
            let sanitized = keyHex
                .lowercased()
                .filter { $0.isHexDigit }
            guard sanitized.isEmpty == false else {
                throw AppError.storageFailure(reason: "Database encryption key is empty.")
            }

            try execute("PRAGMA key = \"x'\(sanitized)'\";")
            let rows = try query("PRAGMA cipher_version;")
            let version = rows.first?.values.first as? String ?? ""
            if version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw AppError.storageFailure(
                    reason: "SQLCipher runtime is not available. Install SQLCipher and relaunch, or disable encryption in settings."
                )
            }
        }
    }

    private func createSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                started_at REAL NOT NULL,
                ended_at REAL,
                status TEXT NOT NULL,
                transcription_provider TEXT NOT NULL,
                summary_status TEXT NOT NULL
            )
            """
        )

        try execute(
            """
            CREATE TABLE IF NOT EXISTS audio_assets (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                local_path TEXT NOT NULL,
                checksum TEXT,
                created_at REAL NOT NULL,
                FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
            )
            """
        )

        try execute(
            """
            CREATE TABLE IF NOT EXISTS transcript_segments (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                start_ms INTEGER NOT NULL,
                end_ms INTEGER NOT NULL,
                text TEXT NOT NULL,
                confidence REAL NOT NULL,
                source_provider TEXT NOT NULL,
                is_final INTEGER NOT NULL,
                speaker_label TEXT,
                FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
            )
            """
        )
        try execute("CREATE INDEX IF NOT EXISTS idx_segments_session_time ON transcript_segments(session_id, start_ms)")
        try ensureTranscriptSegmentsSchema()

        try execute(
            """
            CREATE TABLE IF NOT EXISTS transcript_chunks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                chunk_index INTEGER NOT NULL,
                chunk_text TEXT NOT NULL,
                FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
            )
            """
        )

        try execute(
            """
            CREATE TABLE IF NOT EXISTS summaries (
                session_id TEXT NOT NULL,
                version INTEGER NOT NULL,
                payload_json BLOB NOT NULL,
                generated_at REAL NOT NULL,
                PRIMARY KEY (session_id, version),
                FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
            )
            """
        )

        try execute(
            """
            CREATE TABLE IF NOT EXISTS chat_threads (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                created_at REAL NOT NULL,
                FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
            )
            """
        )

        try execute(
            """
            CREATE TABLE IF NOT EXISTS chat_messages (
                id TEXT PRIMARY KEY,
                thread_id TEXT NOT NULL,
                session_id TEXT NOT NULL,
                role TEXT NOT NULL,
                text TEXT NOT NULL,
                citations_json BLOB NOT NULL,
                created_at REAL NOT NULL,
                FOREIGN KEY(thread_id) REFERENCES chat_threads(id) ON DELETE CASCADE,
                FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
            )
            """
        )

        try execute(
            """
            CREATE TABLE IF NOT EXISTS settings (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                payload_json BLOB NOT NULL
            )
            """
        )

        try execute(
            """
            CREATE TABLE IF NOT EXISTS model_installations (
                model_id TEXT PRIMARY KEY,
                status TEXT NOT NULL,
                progress REAL NOT NULL,
                local_path TEXT,
                last_error TEXT,
                updated_at REAL NOT NULL
            )
            """
        )

        try execute(
            """
            CREATE TABLE IF NOT EXISTS audit_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                category TEXT NOT NULL,
                message TEXT NOT NULL,
                created_at REAL NOT NULL
            )
            """
        )
    }

    private func decodeSession(row: [String: Any?]) throws -> SessionRecord {
        guard
            let id = UUID(uuidString: row["id"] as? String ?? ""),
            let statusRaw = row["status"] as? String,
            let status = SessionStatus(rawValue: statusRaw),
            let providerRaw = row["transcription_provider"] as? String,
            let provider = TranscriptionProviderType(rawValue: providerRaw),
            let summaryRaw = row["summary_status"] as? String,
            let summaryStatus = SummaryStatus(rawValue: summaryRaw)
        else {
            throw AppError.storageFailure(reason: "Unable to decode session row")
        }

        let started = Date(timeIntervalSince1970: row["started_at"] as? Double ?? 0)
        let ended = (row["ended_at"] as? Double).map(Date.init(timeIntervalSince1970:))

        return SessionRecord(
            id: id,
            name: row["name"] as? String ?? "Untitled",
            startedAt: started,
            endedAt: ended,
            status: status,
            transcriptionProvider: provider,
            summaryStatus: summaryStatus
        )
    }

    private func ensureTranscriptSegmentsSchema() throws {
        if try columnExists(table: "transcript_segments", column: "speaker_label") == false {
            try execute("ALTER TABLE transcript_segments ADD COLUMN speaker_label TEXT")
        }
    }

    private func columnExists(table: String, column: String) throws -> Bool {
        let rows = try query("PRAGMA table_info(\(table));")
        return rows.contains { row in
            (row["name"] as? String)?.lowercased() == column.lowercased()
        }
    }

    private func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw AppError.storageFailure(reason: sqliteErrorMessage())
        }
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement)

        // Some statements (e.g. PRAGMA journal_mode) return rows before SQLITE_DONE.
        // We consume rows until completion and only treat hard sqlite errors as failures.
        var rc = sqlite3_step(statement)
        while rc == SQLITE_ROW {
            rc = sqlite3_step(statement)
        }

        guard rc == SQLITE_DONE else {
            throw AppError.storageFailure(reason: sqliteErrorMessage())
        }
    }

    private func query(_ sql: String, bindings: [SQLiteValue] = []) throws -> [[String: Any?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw AppError.storageFailure(reason: sqliteErrorMessage())
        }
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement)

        var rows: [[String: Any?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: Any?] = [:]
            let columnCount = sqlite3_column_count(statement)
            for i in 0..<columnCount {
                guard let nameC = sqlite3_column_name(statement, i) else { continue }
                let name = String(cString: nameC)
                row[name] = columnValue(statement: statement, index: i)
            }
            rows.append(row)
        }

        return rows
    }

    private func bind(_ bindings: [SQLiteValue], to statement: OpaquePointer) throws {
        for (index, binding) in bindings.enumerated() {
            let position = Int32(index + 1)
            switch binding {
            case .int64(let value):
                sqlite3_bind_int64(statement, position, value)
            case .double(let value):
                sqlite3_bind_double(statement, position, value)
            case .text(let value):
                sqlite3_bind_text(statement, position, (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
            case .blob(let data):
                _ = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, position, bytes.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
                }
            case .null:
                sqlite3_bind_null(statement, position)
            }
        }
    }

    private func columnValue(statement: OpaquePointer, index: Int32) -> Any? {
        let type = sqlite3_column_type(statement, index)
        switch type {
        case SQLITE_INTEGER:
            return sqlite3_column_int64(statement, index)
        case SQLITE_FLOAT:
            return sqlite3_column_double(statement, index)
        case SQLITE_TEXT:
            guard let cString = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: cString)
        case SQLITE_BLOB:
            let length = Int(sqlite3_column_bytes(statement, index))
            guard let bytes = sqlite3_column_blob(statement, index), length > 0 else {
                return Data()
            }
            return Data(bytes: bytes, count: length)
        default:
            return nil
        }
    }

    private func sqliteErrorMessage() -> String {
        if let message = sqlite3_errmsg(db) {
            return String(cString: message)
        }
        return "Unknown sqlite error"
    }
}
