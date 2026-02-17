import Foundation
import CryptoKit

enum SHA256Hasher {
    static func hash(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
