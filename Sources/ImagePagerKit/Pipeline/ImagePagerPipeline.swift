import CoreGraphics
import Foundation

#if canImport(UIKit)
import UIKit
#endif

public actor ImagePagerPipeline {
    private struct FlightKey: Hashable {
        let userScopeId: String
        let digest: String
    }

    private struct Flight {
        var continuations: [UUID: CheckedContinuation<ImagePagerImage, Error>] = [:]
        var task: Task<Void, Never>?
    }

    public static let shared = ImagePagerPipeline()

    private let configuration: ImagePagerConfiguration
    private let dataFetcher: ImageDataFetcherBox
    private let memoryCache: MemoryImageCache
    private let diskCache: DiskImageCache

    private var activeUserScopeId: String?
    private var scopeGeneration: UInt64 = 0
    private var inFlight: [FlightKey: Flight] = [:]

    #if canImport(UIKit)
    private let memoryWarningObserver: NSObjectProtocol?
    #endif

    public init(
        configuration: ImagePagerConfiguration = ImagePagerConfiguration(),
        dataFetcher: any ImageDataFetching = URLSession.shared
    ) {
        self.configuration = configuration
        self.dataFetcher = ImageDataFetcherBox(dataFetcher)
        self.memoryCache = MemoryImageCache(capacityBytes: configuration.memoryCapacityBytes)
        self.diskCache = DiskImageCache(
            rootDirectory: configuration.diskRootURL ?? Self.defaultDiskRoot(),
            ttl: configuration.diskTTL,
            capacityBytes: configuration.diskCapacityBytes
        )

        #if canImport(UIKit)
        self.memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task {
                await self?.evictMemoryForPressure()
            }
        }
        #endif
    }

    deinit {
        #if canImport(UIKit)
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
        #endif
    }

    public func switchUserScope(to newUserScopeId: String) async {
        let previousScope = activeUserScopeId
        activeUserScopeId = newUserScopeId
        scopeGeneration &+= 1

        let flights = inFlight.values
        inFlight.removeAll(keepingCapacity: false)

        for flight in flights {
            flight.task?.cancel()
            for continuation in flight.continuations.values {
                continuation.resume(throwing: CancellationError())
            }
        }

        await memoryCache.removeAll()

        guard let previousScope, previousScope != newUserScopeId else {
            return
        }

        let diskCache = self.diskCache
        Task.detached(priority: .utility) {
            await diskCache.removeScope(previousScope)
        }
    }

    public func loadImage(
        from url: URL,
        variant: ImageVariant,
        requestBuilder: @escaping @Sendable (URL) -> URLRequest,
        userScopeId: String,
        targetSize: CGSize,
        displayScale: CGFloat,
        cachePolicy: ImageRequestCachePolicy = .cacheEnabled
    ) async throws -> ImagePagerImage {
        if activeUserScopeId == nil {
            activeUserScopeId = userScopeId
        }

        let normalizedTargetSize = Self.normalize(targetSize)
        let normalizedScale = max(displayScale, 1)
        let cacheKey = ImageCacheKey(url: url, variant: variant)

        if cachePolicy.memoryEnabled,
           let cachedImage = await memoryCache.image(for: cacheKey, userScopeId: userScopeId),
           Self.image(cachedImage, satisfies: normalizedTargetSize, displayScale: normalizedScale) {
            emit(.cacheHit(cacheKeyHash: cacheKey.digest, variant: variant, source: .memory))
            return cachedImage
        }

        if cachePolicy.diskEnabled,
           let cachedData = await diskCache.cachedData(for: cacheKey, userScopeId: userScopeId),
           let decoded = try await decodeCachedImage(
               data: cachedData,
               cacheKey: cacheKey,
               targetSize: normalizedTargetSize,
               displayScale: normalizedScale
           ) {
            if cachePolicy.memoryEnabled {
                await memoryCache.store(decoded, for: cacheKey, userScopeId: userScopeId)
            }

            return decoded
        }

        emit(.cacheMiss(cacheKeyHash: cacheKey.digest, variant: variant))

        let flightKey = FlightKey(userScopeId: userScopeId, digest: cacheKey.digest)
        if inFlight[flightKey] == nil {
            inFlight[flightKey] = Flight()
        }

        let token = UUID()
        let generation = scopeGeneration

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueueWaiter(
                    token: token,
                    continuation: continuation,
                    for: flightKey,
                    starter: makeStarter(
                        url: url,
                        cacheKey: cacheKey,
                        requestBuilder: requestBuilder,
                        userScopeId: userScopeId,
                        targetSize: normalizedTargetSize,
                        displayScale: normalizedScale,
                        cachePolicy: cachePolicy,
                        generation: generation
                    )
                )
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(token: token, for: flightKey)
            }
        }
    }

    package func retainPagerImages(for urls: [URL], userScopeId: String) async {
        let digests = Set(urls.map { ImageCacheKey(url: $0, variant: .pager).digest })
        await memoryCache.retainPagerDigests(digests, userScopeId: userScopeId)
    }

    func debugContainsMemoryImage(for url: URL, variant: ImageVariant, userScopeId: String) async -> Bool {
        await memoryCache.containsImage(for: ImageCacheKey(url: url, variant: variant), userScopeId: userScopeId)
    }

    func debugDiskFileURL(for url: URL, variant: ImageVariant, userScopeId: String) async -> URL {
        await diskCache.fileURL(for: ImageCacheKey(url: url, variant: variant), userScopeId: userScopeId)
    }

    private nonisolated static func defaultDiskRoot() -> URL {
        let baseDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory

        return baseDirectory.appending(path: "ZoomableImageManagerCache", directoryHint: .isDirectory)
    }

    private func evictMemoryForPressure() async {
        await memoryCache.removeAll()
    }

    private func enqueueWaiter(
        token: UUID,
        continuation: CheckedContinuation<ImagePagerImage, Error>,
        for key: FlightKey,
        starter: @escaping @Sendable () async -> Result<ImagePagerImage, Error>
    ) {
        guard var flight = inFlight[key] else {
            continuation.resume(throwing: CancellationError())
            return
        }

        flight.continuations[token] = continuation
        let shouldStart = flight.task == nil
        inFlight[key] = flight

        guard shouldStart else {
            return
        }

        let task = Task(priority: .utility) { [weak self] in
            guard let self else {
                return
            }

            let result = await starter()
            await self.completeFlight(for: key, with: result)
        }

        inFlight[key]?.task = task
    }

    private func cancelWaiter(token: UUID, for key: FlightKey) {
        guard var flight = inFlight[key] else {
            return
        }

        guard let continuation = flight.continuations.removeValue(forKey: token) else {
            if flight.continuations.isEmpty, flight.task == nil {
                inFlight.removeValue(forKey: key)
            }

            return
        }

        continuation.resume(throwing: CancellationError())

        if flight.continuations.isEmpty {
            flight.task?.cancel()
            inFlight.removeValue(forKey: key)
        } else {
            inFlight[key] = flight
        }
    }

    private func completeFlight(for key: FlightKey, with result: Result<ImagePagerImage, Error>) {
        guard let flight = inFlight.removeValue(forKey: key) else {
            return
        }

        for continuation in flight.continuations.values {
            continuation.resume(with: result)
        }
    }

    private func makeStarter(
        url: URL,
        cacheKey: ImageCacheKey,
        requestBuilder: @escaping @Sendable (URL) -> URLRequest,
        userScopeId: String,
        targetSize: CGSize,
        displayScale: CGFloat,
        cachePolicy: ImageRequestCachePolicy,
        generation: UInt64
    ) -> @Sendable () async -> Result<ImagePagerImage, Error> {
        let dataFetcher = self.dataFetcher
        let memoryCache = self.memoryCache
        let diskCache = self.diskCache
        let metricsSink = self.configuration.metricsSink

        return { [self] in
            do {
                let request = requestBuilder(url)

                let downloadStart = Date()
                let (data, _) = try await dataFetcher.data(for: request)
                metricsSink?.record(.downloadCompleted(
                    cacheKeyHash: cacheKey.digest,
                    variant: cacheKey.variant,
                    duration: Date().timeIntervalSince(downloadStart)
                ))

                try Task.checkCancellation()
                guard await self.isCurrentGeneration(generation) else {
                    throw CancellationError()
                }

                let sourceType = ImageCodec.preferredUTType(for: data)

                let decodeStart = Date()
                let decoded = try await Self.decodeImage(
                    data: data,
                    targetSize: targetSize,
                    displayScale: displayScale
                )
                metricsSink?.record(.decodeCompleted(
                    cacheKeyHash: cacheKey.digest,
                    variant: cacheKey.variant,
                    duration: Date().timeIntervalSince(decodeStart),
                    source: .network
                ))

                try Task.checkCancellation()
                guard await self.isCurrentGeneration(generation) else {
                    throw CancellationError()
                }

                if cachePolicy.memoryEnabled {
                    await memoryCache.store(decoded, for: cacheKey, userScopeId: userScopeId)
                }

                if cachePolicy.diskEnabled {
                    let encoded = try await Self.encodeImage(
                        decoded.cgImage,
                        preferredUTType: sourceType
                    )

                    try Task.checkCancellation()
                    guard await self.isCurrentGeneration(generation) else {
                        throw CancellationError()
                    }

                    await diskCache.store(encoded, for: cacheKey, userScopeId: userScopeId)
                }

                return .success(decoded)
            } catch {
                return .failure(error)
            }
        }
    }

    private func decodeCachedImage(
        data: Data,
        cacheKey: ImageCacheKey,
        targetSize: CGSize,
        displayScale: CGFloat
    ) async throws -> ImagePagerImage? {
        let decodeStart = Date()
        let decoded = try await Self.decodeImage(
            data: data,
            targetSize: targetSize,
            displayScale: displayScale
        )

        guard Self.image(decoded, satisfies: targetSize, displayScale: displayScale) else {
            return nil
        }

        emit(.cacheHit(cacheKeyHash: cacheKey.digest, variant: cacheKey.variant, source: .disk))
        emit(.decodeCompleted(
            cacheKeyHash: cacheKey.digest,
            variant: cacheKey.variant,
            duration: Date().timeIntervalSince(decodeStart),
            source: .disk
        ))

        return decoded
    }

    private func isCurrentGeneration(_ generation: UInt64) -> Bool {
        generation == scopeGeneration
    }

    private func emit(_ event: ImagePagerMetricEvent) {
        configuration.metricsSink?.record(event)
    }

    private nonisolated static func normalize(_ size: CGSize) -> CGSize {
        CGSize(width: max(size.width, 1), height: max(size.height, 1))
    }

    private nonisolated static func decodeImage(
        data: Data,
        targetSize: CGSize,
        displayScale: CGFloat
    ) async throws -> ImagePagerImage {
        try await Task.detached(priority: .utility) {
            try ImageCodec.downsample(data: data, targetSize: targetSize, displayScale: displayScale)
        }.value
    }

    private nonisolated static func encodeImage(
        _ image: CGImage,
        preferredUTType: String?
    ) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try ImageCodec.encode(image: image, preferredUTType: preferredUTType)
        }.value
    }

    private nonisolated static func image(
        _ image: ImagePagerImage,
        satisfies targetSize: CGSize,
        displayScale: CGFloat
    ) -> Bool {
        let targetPixelWidth = max(targetSize.width * max(displayScale, 1), 1)
        let targetPixelHeight = max(targetSize.height * max(displayScale, 1), 1)
        let widthRatio = targetPixelWidth / max(image.pixelSize.width, 1)
        let heightRatio = targetPixelHeight / max(image.pixelSize.height, 1)

        return min(widthRatio, heightRatio) <= 1.02
    }
}
