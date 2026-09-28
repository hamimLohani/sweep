import Foundation

public struct AppCacheInfo: Codable {
    public let appInfo: AppInfo
    public let cacheItems: [LeftoverItem]

    public var totalSizeBytes: Int64 {
        cacheItems.reduce(0) { $0 + $1.sizeBytes }
    }

    public init(appInfo: AppInfo, cacheItems: [LeftoverItem]) {
        self.appInfo = appInfo
        self.cacheItems = cacheItems
    }
}

public final class CacheScanner {
    private let fileManager: FileManager
    private let safetyGuard: SafetyGuard
    private let customHomeDirectory: URL?

    public init(
        fileManager: FileManager = .default,
        safetyGuard: SafetyGuard? = nil,
        customHomeDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.customHomeDirectory = customHomeDirectory
        self.safetyGuard = safetyGuard ?? SafetyGuard(fileManager: fileManager, customAllowedRoot: customHomeDirectory)
    }

    /// Scans cache items for a specific application
    public func scanCache(for appInfo: AppInfo) -> AppCacheInfo {
        var items: [LeftoverItem] = []
        var seenPaths: Set<String> = []

        let homeDir = customHomeDirectory ?? fileManager.homeDirectoryForCurrentUser
        let bundleID = appInfo.bundleIdentifier
        let bundleName = appInfo.bundleName

        func evaluateCacheItem(url: URL, category: String, reason: String) {
            let canonical = url.resolvingSymlinksInPath().standardized.path
            guard !seenPaths.contains(canonical) else { return }
            guard fileManager.fileExists(atPath: url.path) else { return }

            // Validate against safety rules in cache-only mode
            do {
                try safetyGuard.validate(itemURL: url, for: appInfo, isCacheOnly: true)
            } catch {
                return
            }

            let size = calculateSize(of: url)
            guard size > 0 else { return }

            seenPaths.insert(canonical)
            let requiresPrivilege = !PrivilegeHandler.shared.canWrite(to: url) || url.path.hasPrefix("/Library") || url.path.hasPrefix("/private/var") || url.path.hasPrefix("/var")

            items.append(LeftoverItem(
                url: url,
                sizeBytes: size,
                category: category,
                confidence: .high,
                matchReason: reason,
                requiresPrivilege: requiresPrivilege
            ))
        }

        // 1. User Caches directory: ~/Library/Caches
        let userCaches = homeDir.appendingPathComponent("Library/Caches")
        if fileManager.fileExists(atPath: userCaches.path) {
            if !bundleID.isEmpty {
                let idURL = userCaches.appendingPathComponent(bundleID)
                evaluateCacheItem(url: idURL, category: "User Caches", reason: "Application cache folder (\(bundleID))")

                if let contents = try? fileManager.contentsOfDirectory(at: userCaches, includingPropertiesForKeys: nil) {
                    for sub in contents {
                        let name = sub.lastPathComponent
                        if name.hasPrefix(bundleID + ".") {
                            evaluateCacheItem(url: sub, category: "User Caches", reason: "Sub-service cache folder (\(name))")
                        }
                    }
                }
            }

            if bundleName.count >= 3 && !["System", "Library", "Apple", "Google", "Microsoft"].contains(bundleName) {
                let nameURL = userCaches.appendingPathComponent(bundleName)
                evaluateCacheItem(url: nameURL, category: "User Caches", reason: "Application cache folder (\(bundleName))")
            }
        }

        // 2. Darwin User Cache Directory (confstr _CS_DARWIN_USER_CACHE_DIR)
        if let darwinCache = DarwinDirs.userCacheDir, fileManager.fileExists(atPath: darwinCache.path) {
            if let contents = try? fileManager.contentsOfDirectory(at: darwinCache, includingPropertiesForKeys: nil) {
                for item in contents {
                    let name = item.lastPathComponent
                    if !bundleID.isEmpty && (name == bundleID || name.hasPrefix(bundleID + ".") || name.contains("+" + bundleID)) {
                        evaluateCacheItem(url: item, category: "Darwin Cache Directory", reason: "Darwin system cache (\(name))")
                    }
                }
            }
        }

        // 3. Darwin User Temp Directory (confstr _CS_DARWIN_USER_TEMP_DIR)
        if let darwinTemp = DarwinDirs.userTempDir, fileManager.fileExists(atPath: darwinTemp.path) {
            if let contents = try? fileManager.contentsOfDirectory(at: darwinTemp, includingPropertiesForKeys: nil) {
                for item in contents {
                    let name = item.lastPathComponent
                    if !bundleID.isEmpty && (name == bundleID || name.hasPrefix(bundleID + ".") || name.contains("+" + bundleID)) {
                        evaluateCacheItem(url: item, category: "Darwin Temp Directory", reason: "Darwin temporary cache (\(name))")
                    }
                }
            }
        }

        // 4. Sandbox Containers: ~/Library/Containers/<bundleID>/Data/Library/Caches
        if !bundleID.isEmpty {
            let containerDir = homeDir.appendingPathComponent("Library/Containers/\(bundleID)/Data/Library")
            let containerCaches = containerDir.appendingPathComponent("Caches")
            evaluateCacheItem(url: containerCaches, category: "Sandbox Caches", reason: "Sandboxed application cache (\(bundleID))")

            let containerWebKit = containerDir.appendingPathComponent("WebKit")
            evaluateCacheItem(url: containerWebKit, category: "Sandbox WebKit Cache", reason: "Sandboxed WebKit cache (\(bundleID))")

            let containerHTTP = containerDir.appendingPathComponent("HTTPStorages")
            evaluateCacheItem(url: containerHTTP, category: "Sandbox HTTP Cache", reason: "Sandboxed network storage cache (\(bundleID))")
        }

        // 5. User HTTPStorages: ~/Library/HTTPStorages/<bundleID>
        if !bundleID.isEmpty {
            let httpStorage = homeDir.appendingPathComponent("Library/HTTPStorages/\(bundleID)")
            evaluateCacheItem(url: httpStorage, category: "HTTPStorages", reason: "Network cache storage (\(bundleID))")
        }

        // 6. User WebKit: ~/Library/WebKit/<bundleID>
        if !bundleID.isEmpty {
            let webKit = homeDir.appendingPathComponent("Library/WebKit/\(bundleID)")
            evaluateCacheItem(url: webKit, category: "WebKit Cache", reason: "WebKit cache storage (\(bundleID))")
        }

        // 7. Saved Application State: ~/Library/Saved Application State/<bundleID>.savedState
        if !bundleID.isEmpty {
            let stateURL = homeDir.appendingPathComponent("Library/Saved Application State/\(bundleID).savedState")
            evaluateCacheItem(url: stateURL, category: "Saved Application State", reason: "Application state cache (\(bundleID))")
        }

        // 8. System-wide Caches: /Library/Caches/<bundleID>
        if !bundleID.isEmpty {
            let sysCache = URL(fileURLWithPath: "/Library/Caches/\(bundleID)")
            evaluateCacheItem(url: sysCache, category: "System Caches", reason: "System-wide application cache (\(bundleID))")
        }

        return AppCacheInfo(appInfo: appInfo, cacheItems: items)
    }

    /// Scans cache for all installed applications
    public func scanAllAppCaches(apps: [AppInfo]? = nil) -> [AppCacheInfo] {
        let resolver = AppResolver(fileManager: fileManager)
        let installedApps = apps ?? resolver.listInstalledApps()
        var results: [AppCacheInfo] = []

        for app in installedApps {
            let cacheInfo = scanCache(for: app)
            if cacheInfo.totalSizeBytes > 0 {
                results.append(cacheInfo)
            }
        }

        return results.sorted { $0.totalSizeBytes > $1.totalSizeBytes }
    }

    private func calculateSize(of url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }

        if !isDir.boolValue {
            let attrs = try? fileManager.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? Int64) ?? 0
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  resourceValues.isRegularFile == true,
                  let size = resourceValues.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }
}
