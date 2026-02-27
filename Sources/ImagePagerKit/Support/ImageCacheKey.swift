import CryptoKit
import Foundation

struct ImageCacheKey: Hashable, Sendable {
    let rawValue: String
    let digest: String
    let variant: ImageVariant

    init(url: URL, variant: ImageVariant) {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil

        let baseString = components?.string ?? url.absoluteString
        let rawValue = "\(baseString)|variant:\(variant.rawValue)"

        self.rawValue = rawValue
        self.digest = SHA256.hash(data: Data(rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
        self.variant = variant
    }
}
