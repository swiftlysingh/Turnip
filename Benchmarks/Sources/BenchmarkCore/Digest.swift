import CryptoKit
import Foundation

enum Digest {
    static func sha256Hex(_ data: Data) -> String {
        CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
