import Foundation

actor MemoryImageCache {
    private struct MemoryKey: Hashable {
        let userScopeId: String
        let digest: String
        let variant: ImageVariant
    }

    private struct Entry {
        let image: ImagePagerImage
        let cost: Int
        var lastAccess: Date
    }

    private let capacityBytes: Int
    private var entries: [MemoryKey: Entry] = [:]
    private var currentCost = 0

    init(capacityBytes: Int) {
        self.capacityBytes = max(capacityBytes, 0)
    }

    func image(for key: ImageCacheKey, userScopeId: String) -> ImagePagerImage? {
        let memoryKey = MemoryKey(userScopeId: userScopeId, digest: key.digest, variant: key.variant)

        guard var entry = entries[memoryKey] else {
            return nil
        }

        entry.lastAccess = Date()
        entries[memoryKey] = entry
        return entry.image
    }

    func store(_ image: ImagePagerImage, for key: ImageCacheKey, userScopeId: String) {
        guard capacityBytes > 0 else {
            return
        }

        let memoryKey = MemoryKey(userScopeId: userScopeId, digest: key.digest, variant: key.variant)
        let cost = max(Int(image.pixelSize.width * image.pixelSize.height * 4), 1)

        if let existing = entries[memoryKey] {
            currentCost -= existing.cost
        }

        entries[memoryKey] = Entry(image: image, cost: cost, lastAccess: Date())
        currentCost += cost
        trimIfNeeded()
    }

    func removeAll() {
        entries.removeAll(keepingCapacity: false)
        currentCost = 0
    }

    func retainPagerDigests(_ digests: Set<String>, userScopeId: String) {
        let keysToRemove = entries.keys.filter { key in
            key.userScopeId == userScopeId && key.variant == .pager && !digests.contains(key.digest)
        }

        remove(keysToRemove)
    }

    func containsImage(for key: ImageCacheKey, userScopeId: String) -> Bool {
        let memoryKey = MemoryKey(userScopeId: userScopeId, digest: key.digest, variant: key.variant)
        return entries[memoryKey] != nil
    }

    private func trimIfNeeded() {
        guard currentCost > capacityBytes else {
            return
        }

        let orderedKeys = entries
            .sorted { $0.value.lastAccess < $1.value.lastAccess }
            .map(\.key)

        for key in orderedKeys where currentCost > capacityBytes {
            remove([key])
        }
    }

    private func remove<S: Sequence>(_ keys: S) where S.Element == MemoryKey {
        for key in keys {
            guard let removed = entries.removeValue(forKey: key) else {
                continue
            }

            currentCost -= removed.cost
        }
    }
}
