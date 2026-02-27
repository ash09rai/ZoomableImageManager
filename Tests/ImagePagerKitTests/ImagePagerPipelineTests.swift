import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ImagePagerKitCore

struct ImagePagerPipelineTests {
    @Test
    func cacheIsolationAcrossUserScopes() async throws {
        let fetcher = TestFetcher(data: try makePNGData(width: 1200, height: 800))
        let (pipeline, rootDirectory) = makePipeline(dataFetcher: fetcher)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let url = URL(string: "https://example.com/image.png?variant=1")!

        _ = try await pipeline.loadImage(
            from: url,
            variant: .pager,
            requestBuilder: { URLRequest(url: $0) },
            userScopeId: "user-a",
            targetSize: CGSize(width: 160, height: 120),
            displayScale: 2
        )

        _ = try await pipeline.loadImage(
            from: url,
            variant: .pager,
            requestBuilder: { URLRequest(url: $0) },
            userScopeId: "user-b",
            targetSize: CGSize(width: 160, height: 120),
            displayScale: 2
        )

        #expect(await fetcher.requestCount() == 2)

        let userAFile = await pipeline.debugDiskFileURL(for: url, variant: .pager, userScopeId: "user-a")
        let userBFile = await pipeline.debugDiskFileURL(for: url, variant: .pager, userScopeId: "user-b")

        #expect(userAFile.path != userBFile.path)
        #expect(FileManager.default.fileExists(atPath: userAFile.path))
        #expect(FileManager.default.fileExists(atPath: userBFile.path))
    }

    @Test
    func switchUserScopeClearsMemoryPurgesDiskAndCancelsInflightTasks() async throws {
        let fetcher = TestFetcher(data: try makePNGData(width: 1000, height: 700))
        let (pipeline, rootDirectory) = makePipeline(dataFetcher: fetcher)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let cachedURL = URL(string: "https://example.com/cached.png")!
        let inflightURL = URL(string: "https://example.com/inflight.png")!

        _ = try await pipeline.loadImage(
            from: cachedURL,
            variant: .pager,
            requestBuilder: { URLRequest(url: $0) },
            userScopeId: "user-a",
            targetSize: CGSize(width: 180, height: 120),
            displayScale: 2
        )

        #expect(await pipeline.debugContainsMemoryImage(for: cachedURL, variant: .pager, userScopeId: "user-a"))

        let cachedFile = await pipeline.debugDiskFileURL(for: cachedURL, variant: .pager, userScopeId: "user-a")
        #expect(FileManager.default.fileExists(atPath: cachedFile.path))

        await fetcher.setSuspended(true)

        let inflightTask = Task {
            try await pipeline.loadImage(
                from: inflightURL,
                variant: .pager,
                requestBuilder: { URLRequest(url: $0) },
                userScopeId: "user-a",
                targetSize: CGSize(width: 180, height: 120),
                displayScale: 2
            )
        }

        try await waitUntil {
            await fetcher.requestCount() == 2
        }

        await pipeline.switchUserScope(to: "user-b")

        do {
            _ = try await inflightTask.value
            throw TestError.expectedCancellation
        } catch is CancellationError {
        }

        #expect(await !pipeline.debugContainsMemoryImage(for: cachedURL, variant: .pager, userScopeId: "user-a"))

        let oldScopeDirectory = cachedFile.deletingLastPathComponent()
        try await waitUntil {
            !FileManager.default.fileExists(atPath: oldScopeDirectory.path)
        }

        await fetcher.resumeAll()
    }

    @Test
    func concurrentLoadsCoalesceIntoSingleNetworkRequest() async throws {
        let fetcher = TestFetcher(data: try makePNGData(width: 1200, height: 800))
        let (pipeline, rootDirectory) = makePipeline(dataFetcher: fetcher)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let url = URL(string: "https://example.com/coalesced.png")!
        await fetcher.setSuspended(true)

        let tasks = (0..<8).map { _ in
            Task {
                try await pipeline.loadImage(
                    from: url,
                    variant: .pager,
                    requestBuilder: { URLRequest(url: $0) },
                    userScopeId: "user-a",
                    targetSize: CGSize(width: 220, height: 160),
                    displayScale: 2
                )
            }
        }

        try await waitUntil {
            await fetcher.requestCount() == 1
        }

        await fetcher.resumeAll()

        for task in tasks {
            _ = try await task.value
        }

        #expect(await fetcher.requestCount() == 1)
    }

    @Test
    func variantsStaySeparated() async throws {
        let fetcher = TestFetcher(data: try makePNGData(width: 1600, height: 1200))
        let (pipeline, rootDirectory) = makePipeline(dataFetcher: fetcher)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let url = URL(string: "https://example.com/variants.png")!

        _ = try await pipeline.loadImage(
            from: url,
            variant: .pager,
            requestBuilder: { URLRequest(url: $0) },
            userScopeId: "user-a",
            targetSize: CGSize(width: 180, height: 120),
            displayScale: 2
        )

        _ = try await pipeline.loadImage(
            from: url,
            variant: .overlay,
            requestBuilder: { URLRequest(url: $0) },
            userScopeId: "user-a",
            targetSize: CGSize(width: 390, height: 844),
            displayScale: 3
        )

        #expect(await fetcher.requestCount() == 2)

        let pagerFile = await pipeline.debugDiskFileURL(for: url, variant: .pager, userScopeId: "user-a")
        let overlayFile = await pipeline.debugDiskFileURL(for: url, variant: .overlay, userScopeId: "user-a")

        #expect(pagerFile.path != overlayFile.path)
        #expect(FileManager.default.fileExists(atPath: pagerFile.path))
        #expect(FileManager.default.fileExists(atPath: overlayFile.path))

        _ = try await pipeline.loadImage(
            from: url,
            variant: .pager,
            requestBuilder: { URLRequest(url: $0) },
            userScopeId: "user-a",
            targetSize: CGSize(width: 180, height: 120),
            displayScale: 2
        )

        _ = try await pipeline.loadImage(
            from: url,
            variant: .overlay,
            requestBuilder: { URLRequest(url: $0) },
            userScopeId: "user-a",
            targetSize: CGSize(width: 390, height: 844),
            displayScale: 3
        )

        #expect(await fetcher.requestCount() == 2)
    }

    @Test
    func downsamplingStaysWithinRequestedBounds() async throws {
        let fetcher = TestFetcher(data: try makePNGData(width: 1200, height: 800))
        let (pipeline, rootDirectory) = makePipeline(dataFetcher: fetcher)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let url = URL(string: "https://example.com/downsampled.png")!
        let image = try await pipeline.loadImage(
            from: url,
            variant: .pager,
            requestBuilder: { URLRequest(url: $0) },
            userScopeId: "user-a",
            targetSize: CGSize(width: 100, height: 50),
            displayScale: 2
        )

        #expect(image.pixelSize.width <= 200.5)
        #expect(image.pixelSize.height <= 100.5)
    }

    @Test
    func loadImageCoversMemoryDiskAndSelectiveCachingPaths() async throws {
        let fetcher = TestFetcher(data: try makePNGData(width: 1400, height: 900))
        let (pipeline, rootDirectory) = makePipeline(dataFetcher: fetcher)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let uncachedURL = URL(string: "https://example.com/uncached.png")!
        let memoryOnlyURL = URL(string: "https://example.com/memory-only.png")!
        let diskURL = URL(string: "https://example.com/disk.png")!
        let upgradedURL = URL(string: "https://example.com/upgraded.png")!

        _ = try await pipeline.loadImage(
            from: uncachedURL,
            variant: .pager,
            requestBuilder: { URLRequest(url: $0) },
            userScopeId: "user-a",
            targetSize: CGSize(width: 120, height: 80),
            displayScale: 2,
            cachePolicy: .cacheDisabled()
        )

        _ = try await pipeline.loadImage(
            from: uncachedURL,
            variant: .pager,
            requestBuilder: { URLRequest(url: $0) },
            userScopeId: "user-a",
            targetSize: CGSize(width: 120, height: 80),
            displayScale: 2,
            cachePolicy: .cacheDisabled()
        )

        let uncachedFile = await pipeline.debugDiskFileURL(for: uncachedURL, variant: .pager, userScopeId: "user-a")
        #expect(await fetcher.requestCount() == 2)
        #expect(!FileManager.default.fileExists(atPath: uncachedFile.path))
        #expect(await !pipeline.debugContainsMemoryImage(for: uncachedURL, variant: .pager, userScopeId: "user-a"))

        _ = try await pipeline.loadImage(
            from: memoryOnlyURL,
            variant: .pager,
            requestBuilder: { URLRequest(url: $0) },
            userScopeId: "user-a",
            targetSize: CGSize(width: 120, height: 80),
            displayScale: 2,
            cachePolicy: .cacheDisabled(allowMemoryCache: true)
        )

        _ = try await pipeline.loadImage(
            from: memoryOnlyURL,
            variant: .pager,
            requestBuilder: { URLRequest(url: $0) },
            userScopeId: "user-a",
            targetSize: CGSize(width: 120, height: 80),
            displayScale: 2,
            cachePolicy: .cacheDisabled(allowMemoryCache: true)
        )

        #expect(await fetcher.requestCount() == 3)
        #expect(await pipeline.debugContainsMemoryImage(for: memoryOnlyURL, variant: .pager, userScopeId: "user-a"))

        await pipeline.switchUserScope(to: "user-a")

        _ = try await pipeline.loadImage(
            from: memoryOnlyURL,
            variant: .pager,
            requestBuilder: { URLRequest(url: $0) },
            userScopeId: "user-a",
            targetSize: CGSize(width: 120, height: 80),
            displayScale: 2,
            cachePolicy: .cacheDisabled(allowMemoryCache: true)
        )

        #expect(await fetcher.requestCount() == 4)

        _ = try await pipeline.loadImage(
            from: diskURL,
            variant: .pager,
            requestBuilder: { URLRequest(url: $0) },
            userScopeId: "user-a",
            targetSize: CGSize(width: 120, height: 80),
            displayScale: 2
        )

        await pipeline.switchUserScope(to: "user-a")

        _ = try await pipeline.loadImage(
            from: diskURL,
            variant: .pager,
            requestBuilder: { URLRequest(url: $0) },
            userScopeId: "user-a",
            targetSize: CGSize(width: 120, height: 80),
            displayScale: 2
        )

        #expect(await fetcher.requestCount() == 5)

        _ = try await pipeline.loadImage(
            from: upgradedURL,
            variant: .pager,
            requestBuilder: { URLRequest(url: $0) },
            userScopeId: "user-a",
            targetSize: CGSize(width: 40, height: 30),
            displayScale: 1
        )

        await pipeline.switchUserScope(to: "user-a")

        _ = try await pipeline.loadImage(
            from: upgradedURL,
            variant: .pager,
            requestBuilder: { URLRequest(url: $0) },
            userScopeId: "user-a",
            targetSize: CGSize(width: 400, height: 280),
            displayScale: 2
        )

        #expect(await fetcher.requestCount() == 7)
    }

    @Test
    func cancellationCanRemoveOnlyOneWaiterFromASharedFlight() async throws {
        let fetcher = TestFetcher(data: try makePNGData(width: 1200, height: 800))
        let (pipeline, rootDirectory) = makePipeline(dataFetcher: fetcher)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let url = URL(string: "https://example.com/shared-flight.png")!
        await fetcher.setSuspended(true)

        let cancelled = Task {
            try await pipeline.loadImage(
                from: url,
                variant: .pager,
                requestBuilder: { URLRequest(url: $0) },
                userScopeId: "user-a",
                targetSize: CGSize(width: 180, height: 120),
                displayScale: 2
            )
        }

        let surviving = Task {
            try await pipeline.loadImage(
                from: url,
                variant: .pager,
                requestBuilder: { URLRequest(url: $0) },
                userScopeId: "user-a",
                targetSize: CGSize(width: 180, height: 120),
                displayScale: 2
            )
        }

        try await waitUntil {
            await fetcher.requestCount() == 1
        }

        cancelled.cancel()
        await fetcher.resumeAll()

        do {
            _ = try await cancelled.value
            throw TestError.expectedCancellation
        } catch is CancellationError {
        }

        let image = try await surviving.value
        #expect(image.pixelSize.width > 0)
        #expect(await fetcher.requestCount() == 1)
    }

    @Test
    func metricsSinkRecordsMissDownloadDecodeAndHits() async throws {
        let recorder = EventRecorder()
        let fetcher = TestFetcher(data: try makePNGData(width: 900, height: 600))
        let rootDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let pipeline = ImagePagerPipeline(
            configuration: ImagePagerConfiguration(
                diskTTL: 14 * 24 * 60 * 60,
                diskCapacityBytes: 20_000_000,
                memoryCapacityBytes: 20_000_000,
                diskRootURL: rootDirectory,
                metricsSink: ImagePagerMetricsSink { event in
                    recorder.record(event)
                }
            ),
            dataFetcher: fetcher
        )
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let url = URL(string: "https://example.com/metrics.png")!

        _ = try await pipeline.loadImage(
            from: url,
            variant: .pager,
            requestBuilder: { URLRequest(url: $0) },
            userScopeId: "user-a",
            targetSize: CGSize(width: 120, height: 80),
            displayScale: 2
        )

        _ = try await pipeline.loadImage(
            from: url,
            variant: .pager,
            requestBuilder: { URLRequest(url: $0) },
            userScopeId: "user-a",
            targetSize: CGSize(width: 120, height: 80),
            displayScale: 2
        )

        await pipeline.switchUserScope(to: "user-a")

        _ = try await pipeline.loadImage(
            from: url,
            variant: .pager,
            requestBuilder: { URLRequest(url: $0) },
            userScopeId: "user-a",
            targetSize: CGSize(width: 120, height: 80),
            displayScale: 2
        )

        let events = recorder.snapshot()
        let memoryHits = events.filter { event in
            if case .cacheHit(_, _, .memory) = event {
                return true
            }

            return false
        }
        let diskHits = events.filter { event in
            if case .cacheHit(_, _, .disk) = event {
                return true
            }

            return false
        }
        let misses = events.filter { event in
            if case .cacheMiss = event {
                return true
            }

            return false
        }
        let downloads = events.filter { event in
            if case .downloadCompleted = event {
                return true
            }

            return false
        }
        let decodes = events.filter { event in
            if case .decodeCompleted = event {
                return true
            }

            return false
        }

        #expect(misses.count == 1)
        #expect(downloads.count == 1)
        #expect(memoryHits.count == 1)
        #expect(diskHits.count == 1)
        #expect(decodes.count >= 2)
    }
}

struct MemoryImageCacheTests {
    @Test
    func zeroCapacityStoresNothing() async throws {
        let cache = MemoryImageCache(capacityBytes: 0)
        let url = URL(string: "https://example.com/zero.png")!
        let key = ImageCacheKey(url: url, variant: .pager)

        await cache.store(try makeTestImage(width: 10, height: 10), for: key, userScopeId: "user-a")

        #expect(await cache.image(for: key, userScopeId: "user-a") == nil)
        #expect(await !cache.containsImage(for: key, userScopeId: "user-a"))
    }

    @Test
    func trimAndRetentionRespectScopeAndVariant() async throws {
        let cache = MemoryImageCache(capacityBytes: 500)
        let pagerURL1 = URL(string: "https://example.com/pager-1.png")!
        let pagerURL2 = URL(string: "https://example.com/pager-2.png")!
        let overlayURL = URL(string: "https://example.com/overlay.png")!

        let pagerKey1 = ImageCacheKey(url: pagerURL1, variant: .pager)
        let pagerKey2 = ImageCacheKey(url: pagerURL2, variant: .pager)
        let overlayKey = ImageCacheKey(url: overlayURL, variant: .overlay)

        let trimCache = MemoryImageCache(capacityBytes: 300)
        await trimCache.store(try makeTestImage(width: 10, height: 10), for: pagerKey1, userScopeId: "user-a")
        #expect(await !trimCache.containsImage(for: pagerKey1, userScopeId: "user-a"))

        await cache.store(try makeTestImage(width: 4, height: 4), for: pagerKey1, userScopeId: "user-a")
        await cache.store(try makeTestImage(width: 4, height: 4), for: pagerKey2, userScopeId: "user-a")

        await cache.store(try makeTestImage(width: 4, height: 4), for: overlayKey, userScopeId: "user-a")
        await cache.store(try makeTestImage(width: 4, height: 4), for: pagerKey1, userScopeId: "user-b")

        await cache.retainPagerDigests(Set([pagerKey2.digest]), userScopeId: "user-a")

        #expect(await !cache.containsImage(for: pagerKey1, userScopeId: "user-a"))
        #expect(await cache.containsImage(for: pagerKey2, userScopeId: "user-a"))
        #expect(await cache.containsImage(for: overlayKey, userScopeId: "user-a"))
        #expect(await cache.containsImage(for: pagerKey1, userScopeId: "user-b"))

        await cache.removeAll()

        #expect(await !cache.containsImage(for: pagerKey2, userScopeId: "user-a"))
        #expect(await !cache.containsImage(for: overlayKey, userScopeId: "user-a"))
    }
}

struct DiskImageCacheTests {
    @Test
    func cachedDataReturnsNilWhenFileIsMissing() async throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let cache = DiskImageCache(rootDirectory: rootDirectory, ttl: 60, capacityBytes: 128)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let key = ImageCacheKey(url: URL(string: "https://example.com/missing.png")!, variant: .pager)
        #expect(await cache.cachedData(for: key, userScopeId: "user-a") == nil)
    }

    @Test
    func diskCacheExpiresOldFilesAndTrimsLeastRecentlyUsed() async throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let cache = DiskImageCache(rootDirectory: rootDirectory, ttl: 60, capacityBytes: 5)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let firstKey = ImageCacheKey(url: URL(string: "https://example.com/first.png")!, variant: .pager)
        await cache.store(Data("123456".utf8), for: firstKey, userScopeId: "user-a")
        #expect(await cache.cachedData(for: firstKey, userScopeId: "user-a") == nil)

        let expiringRoot = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let expiringCache = DiskImageCache(rootDirectory: expiringRoot, ttl: 60, capacityBytes: 128)
        defer { try? FileManager.default.removeItem(at: expiringRoot) }

        let expiringKey = ImageCacheKey(url: URL(string: "https://example.com/expiring.png")!, variant: .pager)
        await expiringCache.store(Data("stale".utf8), for: expiringKey, userScopeId: "user-a")

        let expiringURL = await expiringCache.fileURL(for: expiringKey, userScopeId: "user-a")
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: expiringURL.path)

        #expect(await expiringCache.cachedData(for: expiringKey, userScopeId: "user-a") == nil)
        #expect(!FileManager.default.fileExists(atPath: expiringURL.path))

        await expiringCache.removeScope("user-a")
        #expect(!FileManager.default.fileExists(atPath: expiringURL.deletingLastPathComponent().path))
    }
}

struct SupportTypeTests {
    @Test
    func cachePolicyHelpersMetricsSinkAndFetcherBoxWork() async throws {
        #expect(ImageRequestCachePolicy.cacheEnabled.diskEnabled)
        #expect(ImageRequestCachePolicy.cacheEnabled.memoryEnabled)
        #expect(!ImageRequestCachePolicy.cacheDisabled().diskEnabled)
        #expect(!ImageRequestCachePolicy.cacheDisabled().memoryEnabled)
        #expect(ImageRequestCachePolicy.cacheDisabled(allowMemoryCache: true).memoryEnabled)

        let recorder = EventRecorder()
        let sink = ImagePagerMetricsSink { event in
            recorder.record(event)
        }
        sink.record(.cacheMiss(cacheKeyHash: "abc", variant: .pager))
        #expect(recorder.snapshot().count == 1)

        let fetcher = TestFetcher(data: Data("payload".utf8))
        let box = ImageDataFetcherBox(fetcher)
        let request = URLRequest(url: URL(string: "https://example.com/boxed")!)
        let (data, response) = try await box.data(for: request)

        #expect(data == Data("payload".utf8))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(await fetcher.requestCount() == 1)
    }

    @Test
    func imageCodecAndCacheKeyCoverSuccessAndFailurePaths() throws {
        let pngData = try makePNGData(width: 20, height: 10)
        let cgImage = try makeCGImage(width: 16, height: 8)

        let downsampled = try ImageCodec.downsample(
            data: pngData,
            targetSize: CGSize(width: 100, height: 100),
            displayScale: 1
        )

        #expect(downsampled.pixelSize.width == 20)
        #expect(downsampled.pixelSize.height == 10)
        #expect(ImageCodec.preferredUTType(for: pngData) == UTType.png.identifier)
        #expect(ImageCodec.preferredUTType(for: Data()) == nil)

        let encodedPNG = try ImageCodec.encode(image: cgImage, preferredUTType: nil)
        let encodedJPEG = try ImageCodec.encode(image: cgImage, preferredUTType: UTType.jpeg.identifier)
        #expect(!encodedPNG.isEmpty)
        #expect(!encodedJPEG.isEmpty)

        #expect(throws: ImageCodecError.self) {
            try ImageCodec.downsample(data: Data("not-an-image".utf8), targetSize: CGSize(width: 20, height: 20), displayScale: 1)
        }

        let withFragment = ImageCacheKey(
            url: URL(string: "https://example.com/image.png?x=1#fragment")!,
            variant: .pager
        )
        let withoutFragment = ImageCacheKey(
            url: URL(string: "https://example.com/image.png?x=1")!,
            variant: .pager
        )
        let overlay = ImageCacheKey(
            url: URL(string: "https://example.com/image.png?x=1")!,
            variant: .overlay
        )

        #expect(withFragment.digest == withoutFragment.digest)
        #expect(withFragment.rawValue == withoutFragment.rawValue)
        #expect(withFragment.digest != overlay.digest)
        #expect(overlay.rawValue.contains("variant:overlay"))
    }
}

private func makePipeline(dataFetcher: any ImageDataFetching) -> (ImagePagerPipeline, URL) {
    let rootDirectory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)

    let pipeline = ImagePagerPipeline(
        configuration: ImagePagerConfiguration(
            diskTTL: 14 * 24 * 60 * 60,
            diskCapacityBytes: 20_000_000,
            memoryCapacityBytes: 20_000_000,
            diskRootURL: rootDirectory
        ),
        dataFetcher: dataFetcher
    )

    return (pipeline, rootDirectory)
}

private func waitUntil(
    timeoutSeconds: TimeInterval = 2,
    intervalNanoseconds: UInt64 = 20_000_000,
    condition: @escaping () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeoutSeconds)

    while Date() < deadline {
        if await condition() {
            return
        }

        try await Task.sleep(nanoseconds: intervalNanoseconds)
    }

    throw TestError.timedOut
}

private func makePNGData(width: Int, height: Int) throws -> Data {
    let image = try makeCGImage(width: width, height: height)
    let data = NSMutableData()

    guard let destination = CGImageDestinationCreateWithData(
        data,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw TestError.failedToCreateImage
    }

    CGImageDestinationAddImage(destination, image, nil)

    guard CGImageDestinationFinalize(destination) else {
        throw TestError.failedToCreateImage
    }

    return data as Data
}

private func makeTestImage(width: Int, height: Int) throws -> ImagePagerImage {
    let image = try makeCGImage(width: width, height: height)
    return ImagePagerImage(
        cgImage: image,
        pixelSize: CGSize(width: width, height: height),
        scale: 1
    )
}

private func makeCGImage(width: Int, height: Int) throws -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw TestError.failedToCreateImage
    }

    context.setFillColor(CGColor(red: 0.21, green: 0.42, blue: 0.78, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    guard let image = context.makeImage() else {
        throw TestError.failedToCreateImage
    }

    return image
}

private enum TestError: Error {
    case expectedCancellation
    case failedToCreateImage
    case timedOut
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ImagePagerMetricEvent] = []

    func record(_ event: ImagePagerMetricEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [ImagePagerMetricEvent] {
        lock.lock()
        let snapshot = events
        lock.unlock()
        return snapshot
    }
}

private actor TestFetcher: ImageDataFetching {
    private let imageData: Data
    private var totalRequests = 0
    private var isSuspended = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(data: Data) {
        self.imageData = data
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        totalRequests += 1

        if isSuspended {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }

        try Task.checkCancellation()

        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        return (imageData, response)
    }

    func setSuspended(_ newValue: Bool) {
        isSuspended = newValue
    }

    func resumeAll() {
        let pendingContinuations = continuations
        continuations.removeAll(keepingCapacity: false)
        isSuspended = false

        for continuation in pendingContinuations {
            continuation.resume()
        }
    }

    func requestCount() -> Int {
        totalRequests
    }
}
