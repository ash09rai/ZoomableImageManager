# ImagePagerKit

`ImagePagerKit` is a SwiftUI-first image pager for iOS 16+ that loads authenticated remote JPEG/PNG images, opens the current image into a fullscreen zoom overlay, and keeps cache state strictly isolated per user scope.

## Features

- Reusable `ImagePagerView` for horizontal remote-image paging.
- Client-injected request authorization via `requestBuilder`.
- Per-request cache overrides with `cacheEnabled` and `cacheDisabled`.
- Two bucketed image variants: `pager` and `overlay`.
- Single-flight request coalescing by `userScopeId + cacheKey`.
- Per-user memory and disk cache isolation with async purge on scope switch.
- Downsampling off the main thread before images reach memory.

## Installation

Add the package and import the module:

```swift
import ImagePagerKit
```

Run the test suite with:

```bash
swift test --enable-swift-testing
```

## Basic Usage

```swift
import SwiftUI
import ImagePagerKit

struct GalleryView: View {
    let urls: [URL]

    var body: some View {
        ImagePagerView(
            urls: urls,
            requestBuilder: { URLRequest(url: $0) },
            userScopeId: "current-user"
        )
        .frame(height: 280)
    }
}
```

## Authenticated Usage

Inject authentication on the client side. `ImagePagerKit` never stores tokens and never uses headers as part of the cache key.

```swift
ImagePagerView(
    urls: urls,
    requestBuilder: { url in
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    },
    userScopeId: session.userID,
    cachePolicyResolver: { url in
        url.lastPathComponent.contains("sensitive")
            ? .cacheDisabled()
            : .cacheEnabled
    }
)
```

If you need in-memory reuse for a sensitive request without disk persistence:

```swift
.cacheDisabled(allowMemoryCache: true)
```

## User Scope Switching

Use the shared pipeline or keep your own pipeline instance and switch it when the active user changes.

```swift
let pipeline = ImagePagerPipeline.shared

Task {
    await pipeline.switchUserScope(to: newUserID)
}
```

The switch operation:

- Cancels all in-flight requests.
- Clears the in-memory cache.
- Increments an internal generation token so stale completions are ignored.
- Purges the old user’s disk folder asynchronously.

Pass the same pipeline into the pager if you do not want to rely on the shared instance:

```swift
ImagePagerView(
    urls: urls,
    requestBuilder: authenticatedRequest,
    userScopeId: session.userID,
    pipeline: pipeline
)
```

## Cache Policy Customization

`ImagePagerPipeline` accepts an `ImagePagerConfiguration`:

```swift
let pipeline = ImagePagerPipeline(
    configuration: ImagePagerConfiguration(
        diskTTL: 7 * 24 * 60 * 60,
        diskCapacityBytes: 300_000_000,
        memoryCapacityBytes: 64_000_000
    )
)
```

Available knobs:

- `diskTTL`: default `14 days`.
- `diskCapacityBytes`: default `~200 MB`.
- `memoryCapacityBytes`: in-memory budget for processed images.
- `diskRootURL`: optional custom cache root.
- `metricsSink`: optional event hook for cache/download/decode metrics.

## Overlay Behavior

- Pinch the centered page past the threshold to open the overlay instantly using the already-rendered pager bitmap.
- The overlay loads only that image and upgrades to the `overlay` variant in the background.
- The overlay preserves zoom and pan state when the higher-resolution image replaces the initial bitmap.
- Double-tap to dismiss.

## Public API Summary

- `ImagePagerView`
- `ImagePagerPipeline`
- `ImagePagerConfiguration`
- `ImageVariant`
- `ImageRequestCachePolicy`
- `ImagePagerMetricsSink`
