import Foundation

enum LMStudioChatCompletionStreamParser {
    enum Event: Equatable {
        case text(String)
        case done
        case ignored
    }

    static func parse(line: String) throws -> Event {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .ignored
        }

        let payload: String
        if trimmed.hasPrefix("data:") {
            payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            payload = trimmed
        }

        guard !payload.isEmpty else {
            return .ignored
        }

        if payload == "[DONE]" {
            return .done
        }

        guard let data = payload.data(using: .utf8) else {
            throw AppError.networkFailure(reason: "LM Studio stream returned non-UTF8 data.")
        }

        if let chunk = extractText(from: data), !chunk.isEmpty {
            return .text(chunk)
        }

        return .ignored
    }

    static func extractText(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            AppLogger.network.debug("LM Studio stream: failed to parse JSON chunk")
            return nil
        }

        if let choices = json["choices"] as? [[String: Any]],
           let first = choices.first {
            if let delta = first["delta"] as? [String: Any],
               let text = extractContent(from: delta["content"]) {
                return text
            }

            if let message = first["message"] as? [String: Any],
               let text = extractContent(from: message["content"]) {
                return text
            }

            if let text = first["text"] as? String, !text.isEmpty {
                return text
            }
        }

        return nil
    }

    private static func extractContent(from raw: Any?) -> String? {
        if let text = raw as? String, !text.isEmpty {
            return text
        }

        if let parts = raw as? [[String: Any]] {
            let stitched = parts.compactMap { part -> String? in
                if let text = part["text"] as? String, !text.isEmpty {
                    return text
                }
                if let inner = part["content"] as? String, !inner.isEmpty {
                    return inner
                }
                return nil
            }.joined()

            return stitched.isEmpty ? nil : stitched
        }

        return nil
    }
}
