import Foundation

#if canImport(UIKit)
import UIKit
#endif

actor DiskImageCache {
    private struct CachedFile {
        let url: URL
        let size: Int
        let accessDate: Date
        let modifiedDate: Date
    }

    private let fileManager = FileManager.default
    private let rootDirectory: URL
    private let ttl: TimeInterval
    private let capacityBytes: Int

    init(rootDirectory: URL, ttl: TimeInterval, capacityBytes: Int) {
        self.rootDirectory = rootDirectory
        self.ttl = ttl
        self.capacityBytes = max(capacityBytes, 0)
    }

    func cachedData(for key: ImageCacheKey, userScopeId: String) -> Data? {
        let url = fileURL(for: key, userScopeId: userScopeId)

        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .contentAccessDateKey]),
              let modifiedDate = values.contentModificationDate else {
            try? fileManager.removeItem(at: url)
            return nil
        }

        if Date().timeIntervalSince(modifiedDate) > ttl {
            try? fileManager.removeItem(at: url)
            return nil
        }

        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            try? fileManager.removeItem(at: url)
            return nil
        }

        touch(url)
        return data
    }

    func store(_ data: Data, for key: ImageCacheKey, userScopeId: String) {
        var scopeDirectory = rootDirectory.appending(path: userScopeId, directoryHint: .isDirectory)

        do {
            try fileManager.createDirectory(at: scopeDirectory, withIntermediateDirectories: true)

            var directoryValues = URLResourceValues()
            directoryValues.isExcludedFromBackup = true
            try? scopeDirectory.setResourceValues(directoryValues)
        } catch {
            return
        }

        let url = fileURL(for: key, userScopeId: userScopeId)

        do {
            try data.write(to: url, options: .atomic)
            touch(url)

            #if canImport(UIKit)
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
            #endif

            trimIfNeeded()
        } catch {
            return
        }
    }

    func removeScope(_ userScopeId: String) {
        let url = rootDirectory.appending(path: userScopeId, directoryHint: .isDirectory)
        try? fileManager.removeItem(at: url)
    }

    func fileURL(for key: ImageCacheKey, userScopeId: String) -> URL {
        rootDirectory
            .appending(path: userScopeId, directoryHint: .isDirectory)
            .appending(path: key.digest, directoryHint: .notDirectory)
    }

    private func touch(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.contentAccessDate = Date()
        try? url.setResourceValues(values)
    }

    private func trimIfNeeded() {
        let files = allFiles()

        let expiredFiles = files.filter { Date().timeIntervalSince($0.modifiedDate) > ttl }
        if !expiredFiles.isEmpty {
            for file in expiredFiles {
                try? fileManager.removeItem(at: file.url)
            }
        }

        guard capacityBytes > 0 else {
            return
        }

        var currentFiles = allFiles()
        var totalBytes = currentFiles.reduce(0) { $0 + $1.size }

        guard totalBytes > capacityBytes else {
            return
        }

        currentFiles.sort { $0.accessDate < $1.accessDate }

        for file in currentFiles where totalBytes > capacityBytes {
            try? fileManager.removeItem(at: file.url)
            totalBytes -= file.size
        }
    }

    private func allFiles() -> [CachedFile] {
        guard let enumerator = fileManager.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentAccessDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [CachedFile] = []

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]),
                  values.isRegularFile == true else {
                continue
            }

            files.append(
                CachedFile(
                    url: url,
                    size: values.fileSize ?? 0,
                    accessDate: values.contentAccessDate ?? .distantPast,
                    modifiedDate: values.contentModificationDate ?? .distantPast
                )
            )
        }

        return files
    }
}
