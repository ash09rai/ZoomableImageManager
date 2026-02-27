import CoreGraphics
import Foundation

public enum ImageVariant: String, CaseIterable, Hashable, Sendable {
    case pager
    case overlay
}

public enum ImageRequestCachePolicy: Hashable, Sendable {
    case cacheEnabled
    case cacheDisabled(allowMemoryCache: Bool = false)

    var diskEnabled: Bool {
        if case .cacheEnabled = self {
            return true
        }

        return false
    }

    var memoryEnabled: Bool {
        switch self {
        case .cacheEnabled:
            return true
        case let .cacheDisabled(allowMemoryCache):
            return allowMemoryCache
        }
    }
}

public enum ImagePagerCacheSource: String, Sendable {
    case memory
    case disk
}

public enum ImagePagerDecodeSource: String, Sendable {
    case disk
    case network
}

public enum ImagePagerMetricEvent: Sendable {
    case cacheHit(cacheKeyHash: String, variant: ImageVariant, source: ImagePagerCacheSource)
    case cacheMiss(cacheKeyHash: String, variant: ImageVariant)
    case downloadCompleted(cacheKeyHash: String, variant: ImageVariant, duration: TimeInterval)
    case decodeCompleted(cacheKeyHash: String, variant: ImageVariant, duration: TimeInterval, source: ImagePagerDecodeSource)
}

public struct ImagePagerMetricsSink: Sendable {
    public let onEvent: @Sendable (ImagePagerMetricEvent) -> Void

    public init(onEvent: @escaping @Sendable (ImagePagerMetricEvent) -> Void) {
        self.onEvent = onEvent
    }

    public func record(_ event: ImagePagerMetricEvent) {
        onEvent(event)
    }
}

public struct ImagePagerConfiguration: Sendable {
    public var diskTTL: TimeInterval
    public var diskCapacityBytes: Int
    public var memoryCapacityBytes: Int
    public var diskRootURL: URL?
    public var metricsSink: ImagePagerMetricsSink?

    public init(
        diskTTL: TimeInterval = 14 * 24 * 60 * 60,
        diskCapacityBytes: Int = 200_000_000,
        memoryCapacityBytes: Int = 48_000_000,
        diskRootURL: URL? = nil,
        metricsSink: ImagePagerMetricsSink? = nil
    ) {
        self.diskTTL = diskTTL
        self.diskCapacityBytes = diskCapacityBytes
        self.memoryCapacityBytes = memoryCapacityBytes
        self.diskRootURL = diskRootURL
        self.metricsSink = metricsSink
    }
}

public protocol ImageDataFetching: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: ImageDataFetching {}

public struct ImagePagerImage: @unchecked Sendable {
    public let cgImage: CGImage
    public let pixelSize: CGSize
    public let scale: CGFloat

    init(cgImage: CGImage, pixelSize: CGSize, scale: CGFloat) {
        self.cgImage = cgImage
        self.pixelSize = pixelSize
        self.scale = scale
    }
}

final class ImageDataFetcherBox: @unchecked Sendable {
    private let base: any ImageDataFetching

    init(_ base: any ImageDataFetching) {
        self.base = base
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await base.data(for: request)
    }
}
