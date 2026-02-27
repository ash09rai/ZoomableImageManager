import ZoomableImageManagerCore
import SwiftUI

public struct DefaultImagePagerPlaceholder: View {
    public init() {}

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.secondary.opacity(0.12))

            ProgressView()
                .tint(.secondary)
        }
    }
}

private struct OverlayItem: Identifiable {
    let id = UUID()
    let url: URL
    let image: ImagePagerImage
    let cachePolicy: ImageRequestCachePolicy
}

public struct ImagePagerView<Placeholder: View>: View {
    private let urls: [URL]
    private let requestBuilder: @Sendable (URL) -> URLRequest
    private let cachePolicyResolver: @Sendable (URL) -> ImageRequestCachePolicy
    private let userScopeId: String
    private let pipeline: ImagePagerPipeline
    private let placeholder: () -> Placeholder

    @State private var selection = 0
    @State private var overlayItem: OverlayItem?

    public init(
        urls: [URL],
        requestBuilder: @escaping @Sendable (URL) -> URLRequest,
        userScopeId: String,
        cachePolicyResolver: @escaping @Sendable (URL) -> ImageRequestCachePolicy = { _ in .cacheEnabled },
        pipeline: ImagePagerPipeline = .shared,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.urls = urls
        self.requestBuilder = requestBuilder
        self.cachePolicyResolver = cachePolicyResolver
        self.userScopeId = userScopeId
        self.pipeline = pipeline
        self.placeholder = placeholder
    }

    public var body: some View {
        GeometryReader { geometry in
            let base = Group {
                if urls.isEmpty {
                    placeholder()
                } else {
                    pagerTabView(for: geometry.size)
                }
            }
            .task(id: retainWindowKey) {
                await pipeline.retainPagerImages(for: retainedURLs, userScopeId: userScopeId)
            }

            #if os(macOS)
            base.sheet(item: $overlayItem) { item in
                overlayView(for: item)
            }
            #else
            base.fullScreenCover(item: $overlayItem) { item in
                overlayView(for: item)
            }
            #endif
        }
    }

    @ViewBuilder
    private func pagerTabView(for targetSize: CGSize) -> some View {
        let content = TabView(selection: $selection) {
            ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                RemoteImagePage(
                    url: url,
                    isCurrent: index == selection,
                    shouldLoad: abs(index - selection) <= 1,
                    targetSize: targetSize,
                    requestBuilder: requestBuilder,
                    cachePolicy: cachePolicyResolver(url),
                    userScopeId: userScopeId,
                    pipeline: pipeline,
                    placeholder: placeholder,
                    onPinch: { image in
                        overlayItem = OverlayItem(
                            url: url,
                            image: image,
                            cachePolicy: cachePolicyResolver(url)
                        )
                    }
                )
                .tag(index)
            }
        }

        #if os(macOS)
        content
        #else
        content.tabViewStyle(
            PageTabViewStyle(indexDisplayMode: urls.count > 1 ? .automatic : .never)
        )
        #endif
    }

    private func overlayView(for item: OverlayItem) -> some View {
        FullScreenImageOverlay(
            url: item.url,
            initialImage: item.image,
            requestBuilder: requestBuilder,
            cachePolicy: item.cachePolicy,
            userScopeId: userScopeId,
            pipeline: pipeline
        )
    }

    private var retainWindowKey: String {
        "\(userScopeId)|\(selection)|\(urls.count)"
    }

    private var retainedURLs: [URL] {
        guard !urls.isEmpty else {
            return []
        }

        let lowerBound = max(selection - 1, 0)
        let upperBound = min(selection + 1, urls.count - 1)
        return Array(urls[lowerBound...upperBound])
    }
}

public extension ImagePagerView where Placeholder == DefaultImagePagerPlaceholder {
    init(
        urls: [URL],
        requestBuilder: @escaping @Sendable (URL) -> URLRequest,
        userScopeId: String,
        cachePolicyResolver: @escaping @Sendable (URL) -> ImageRequestCachePolicy = { _ in .cacheEnabled },
        pipeline: ImagePagerPipeline = .shared
    ) {
        self.init(
            urls: urls,
            requestBuilder: requestBuilder,
            userScopeId: userScopeId,
            cachePolicyResolver: cachePolicyResolver,
            pipeline: pipeline
        ) {
            DefaultImagePagerPlaceholder()
        }
    }
}

private struct RemoteImagePage<Placeholder: View>: View {
    let url: URL
    let isCurrent: Bool
    let shouldLoad: Bool
    let targetSize: CGSize
    let requestBuilder: @Sendable (URL) -> URLRequest
    let cachePolicy: ImageRequestCachePolicy
    let userScopeId: String
    let pipeline: ImagePagerPipeline
    let placeholder: () -> Placeholder
    let onPinch: (ImagePagerImage) -> Void

    @Environment(\.displayScale) private var displayScale
    @StateObject private var loader = PageImageLoader()
    @State private var didTriggerForGesture = false

    var body: some View {
        ZStack {
            if let image = loader.image {
                RenderedImageView(image: image)
                    .transition(.opacity)
            } else {
                placeholder()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .contentShape(Rectangle())
        .gesture(pinchGesture)
        .onAppear {
            refreshLoadingState()
        }
        .onDisappear {
            loader.cancel()
        }
        .onChange(of: shouldLoad) { _ in
            refreshLoadingState()
        }
        .onChange(of: targetSize) { _ in
            refreshLoadingState()
        }
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard isCurrent, !didTriggerForGesture, value > 1.05, let image = loader.image else {
                    return
                }

                didTriggerForGesture = true
                onPinch(image)
            }
            .onEnded { _ in
                didTriggerForGesture = false
            }
    }

    private func refreshLoadingState() {
        guard shouldLoad else {
            loader.release()
            return
        }

        loader.load(
            url: url,
            requestBuilder: requestBuilder,
            cachePolicy: cachePolicy,
            userScopeId: userScopeId,
            targetSize: targetSize,
            displayScale: displayScale,
            pipeline: pipeline
        )
    }
}

@MainActor
private final class PageImageLoader: ObservableObject {
    @Published private(set) var image: ImagePagerImage?

    private var task: Task<Void, Never>?

    func load(
        url: URL,
        requestBuilder: @escaping @Sendable (URL) -> URLRequest,
        cachePolicy: ImageRequestCachePolicy,
        userScopeId: String,
        targetSize: CGSize,
        displayScale: CGFloat,
        pipeline: ImagePagerPipeline
    ) {
        let normalizedSize = CGSize(width: max(targetSize.width, 1), height: max(targetSize.height, 1))

        cancel()
        task = Task {
            do {
                let loadedImage = try await pipeline.loadImage(
                    from: url,
                    variant: .pager,
                    requestBuilder: requestBuilder,
                    userScopeId: userScopeId,
                    targetSize: normalizedSize,
                    displayScale: displayScale,
                    cachePolicy: cachePolicy
                )

                guard !Task.isCancelled else {
                    return
                }

                image = loadedImage
            } catch is CancellationError {
                return
            } catch {
                image = nil
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func release() {
        cancel()
        image = nil
    }
}

private struct FullScreenImageOverlay: View {
    let url: URL
    let initialImage: ImagePagerImage
    let requestBuilder: @Sendable (URL) -> URLRequest
    let cachePolicy: ImageRequestCachePolicy
    let userScopeId: String
    let pipeline: ImagePagerPipeline

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    @State private var displayedImage: ImagePagerImage
    @State private var zoomScale: CGFloat = 1
    @State private var settledZoomScale: CGFloat = 1
    @State private var dragOffset: CGSize = .zero
    @State private var settledDragOffset: CGSize = .zero

    init(
        url: URL,
        initialImage: ImagePagerImage,
        requestBuilder: @escaping @Sendable (URL) -> URLRequest,
        cachePolicy: ImageRequestCachePolicy,
        userScopeId: String,
        pipeline: ImagePagerPipeline
    ) {
        self.url = url
        self.initialImage = initialImage
        self.requestBuilder = requestBuilder
        self.cachePolicy = cachePolicy
        self.userScopeId = userScopeId
        self.pipeline = pipeline
        _displayedImage = State(initialValue: initialImage)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                    .ignoresSafeArea()

                RenderedImageView(image: displayedImage)
                    .scaleEffect(zoomScale)
                    .offset(dragOffset)
                    .gesture(dragGesture)
                    .simultaneousGesture(magnificationGesture)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                dismiss()
            }
            .task(id: overlayLoadKey(for: geometry.size)) {
                do {
                    let upgraded = try await pipeline.loadImage(
                        from: url,
                        variant: .overlay,
                        requestBuilder: requestBuilder,
                        userScopeId: userScopeId,
                        targetSize: geometry.size,
                        displayScale: displayScale,
                        cachePolicy: cachePolicy
                    )

                    guard !Task.isCancelled else {
                        return
                    }

                    displayedImage = upgraded
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
            }
        }
    }

    private func overlayLoadKey(for size: CGSize) -> String {
        "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))@\(displayScale)"
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoomScale = max(settledZoomScale * value, 1)
            }
            .onEnded { value in
                settledZoomScale = max(settledZoomScale * value, 1)
                zoomScale = settledZoomScale

                if settledZoomScale == 1 {
                    dragOffset = .zero
                    settledDragOffset = .zero
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoomScale > 1 else {
                    return
                }

                dragOffset = CGSize(
                    width: settledDragOffset.width + value.translation.width,
                    height: settledDragOffset.height + value.translation.height
                )
            }
            .onEnded { value in
                guard zoomScale > 1 else {
                    dragOffset = .zero
                    settledDragOffset = .zero
                    return
                }

                settledDragOffset = CGSize(
                    width: settledDragOffset.width + value.translation.width,
                    height: settledDragOffset.height + value.translation.height
                )
                dragOffset = settledDragOffset
            }
    }
}

private struct RenderedImageView: View {
    let image: ImagePagerImage

    var body: some View {
        Image(decorative: image.cgImage, scale: image.scale, orientation: .up)
            .resizable()
            .scaledToFit()
    }
}
