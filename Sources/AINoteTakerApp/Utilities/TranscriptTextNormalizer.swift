import Foundation

enum TranscriptTextNormalizer {
    private static let fillerPattern = #"""
    (?ix)
    (?<![\p{L}\p{N}])
    (?:e+h+m+|e+u+h*|u+h+|u+m+|a+h+|h+m+)
    (?![\p{L}\p{N}])
    [\s,.;:!?]*
    """#

    static func normalize(_ text: String) -> String {
        let withDigitSpacing = insertSpacesBetweenLettersAndDigits(in: text)
        let withoutFillers = removeFillers(from: withDigitSpacing)
        return normalizeWhitespaceAndPunctuation(in: withoutFillers)
    }

    private static func insertSpacesBetweenLettersAndDigits(in text: String) -> String {
        var output = ""
        var previousKind: CharacterKind?

        for character in text {
            let kind = CharacterKind(character)
            if shouldInsertSpace(between: previousKind, and: kind),
               output.last?.isWhitespace == false {
                output.append(" ")
            }
            output.append(character)
            previousKind = kind
        }

        return output
    }

    private static func shouldInsertSpace(between previous: CharacterKind?, and current: CharacterKind) -> Bool {
        guard let previous else { return false }
        return (previous == .letter && current == .digit) || (previous == .digit && current == .letter)
    }

    private static func removeFillers(from text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: fillerPattern) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
    }

    private static func normalizeWhitespaceAndPunctuation(in text: String) -> String {
        var cleaned = text.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\s+([,.;:!?])"#,
            with: "$1",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"([,.;:!?])(?=\S)"#,
            with: "$1 ",
            options: .regularExpression
        )
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CharacterKind: Equatable {
        case letter
        case digit
        case other

        init(_ character: Character) {
            if character.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) {
                self = .letter
            } else if character.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
                self = .digit
            } else {
                self = .other
            }
        }
    }
}
