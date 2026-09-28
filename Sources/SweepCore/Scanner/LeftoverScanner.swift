import Foundation

public final class LeftoverScanner {
    private let fileManager: FileManager
    private let rules: [SearchRule]
    private let safetyGuard: SafetyGuard
    private let customHomeDirectory: URL?

    public init(
        fileManager: FileManager = .default,
        rules: [SearchRule]? = nil,
        safetyGuard: SafetyGuard? = nil,
        customHomeDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.rules = rules ?? SearchRuleLoader.loadRules()
        self.customHomeDirectory = customHomeDirectory
        self.safetyGuard = safetyGuard ?? SafetyGuard(fileManager: fileManager, customAllowedRoot: customHomeDirectory)
    }

    /// Scans for all leftover files associated with the specified application
    public func scan(appInfo: AppInfo) throws -> ScanResult {
        // Enforce safety: Refuse to scan sealed core Apple system-protected components
        if appInfo.isSystemApp || SafetyGuard.isProtectedSystemApp(bundleIdentifier: appInfo.bundleIdentifier, bundleURL: appInfo.bundleURL) {
            throw SweepError.protectedSystemComponent("Target '\(appInfo.bundleName)' (\(appInfo.bundleIdentifier)) is a sealed macOS system-protected application.")
        }

        var detectedItems: [LeftoverItem] = []
        var seenPaths: Set<String> = []

        // Step 1: Scan rule-based directories
        for rule in rules {
            guard let baseDirectory = resolveBaseDirectory(for: rule) else { continue }
            guard fileManager.fileExists(atPath: baseDirectory.path) else { continue }

            let itemsInDirectory = (try? fileManager.contentsOfDirectory(
                at: baseDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

            for item in itemsInDirectory {
                let name = item.lastPathComponent
                if let match = ConfidenceScorer.score(itemName: name, appInfo: appInfo, strategy: rule.matchStrategy) {
                    let canonicalPath = item.resolvingSymlinksInPath().standardized.path
                    guard !seenPaths.contains(canonicalPath) else { continue }

                    // Validate against safety rules
                    do {
                        try safetyGuard.validate(itemURL: item, for: appInfo)
                    } catch {
                        // Skip any unsafe path without crashing the scan
                        continue
                    }

                    let size = calculateSize(of: item)
                    seenPaths.insert(canonicalPath)

                    detectedItems.append(LeftoverItem(
                        url: item,
                        sizeBytes: size,
                        category: rule.name,
                        confidence: match.confidence,
                        matchReason: match.reason,
                        requiresPrivilege: rule.requiresPrivilege
                    ))
                }
            }
        }

        // Step 2: Include installer receipt files (.pkg)
        for receiptURL in appInfo.receiptFiles {
            let canonical = receiptURL.resolvingSymlinksInPath().standardized.path
            guard !seenPaths.contains(canonical) else { continue }
            guard fileManager.fileExists(atPath: receiptURL.path) else { continue }

            do {
                try safetyGuard.validate(itemURL: receiptURL, for: appInfo)
                let size = calculateSize(of: receiptURL)
                seenPaths.insert(canonical)

                detectedItems.append(LeftoverItem(
                    url: receiptURL,
                    sizeBytes: size,
                    category: "Package Receipt Files",
                    confidence: .high,
                    matchReason: "Listed in installer receipt (\(receiptURL.lastPathComponent))",
                    requiresPrivilege: receiptURL.path.hasPrefix("/Library") || receiptURL.path.hasPrefix("/usr/local")
                ))
            } catch {
                continue
            }
        }

        // Sort by confidence (High first), then by size descending
        detectedItems.sort {
            if $0.confidence != $1.confidence {
                return $0.confidence > $1.confidence
            }
            return $0.sizeBytes > $1.sizeBytes
        }

        return ScanResult(appInfo: appInfo, leftovers: detectedItems)
    }

    private func resolveBaseDirectory(for rule: SearchRule) -> URL? {
        var template = rule.pathTemplate

        if template.hasPrefix("~/") {
            let home = customHomeDirectory?.path ?? fileManager.homeDirectoryForCurrentUser.path
            template = template.replacingOccurrences(of: "~", with: home)
            return URL(fileURLWithPath: template).standardized
        }

        if template == "$DARWIN_USER_CACHE_DIR" {
            if let customHome = customHomeDirectory {
                return customHome.appendingPathComponent("Caches/Darwin")
            }
            return DarwinDirs.userCacheDir
        }

        if template == "$DARWIN_USER_TEMP_DIR" {
            if let customHome = customHomeDirectory {
                return customHome.appendingPathComponent("Tmp/Darwin")
            }
            return DarwinDirs.userTempDir
        }

        // System directories: if customHome is set (testing mode), redirect to sandbox
        if let customHome = customHomeDirectory {
            if template.hasPrefix("/Library") {
                let relative = String(template.dropFirst("/Library".count))
                return customHome.appendingPathComponent("SystemLibrary").appendingPathComponent(relative).standardized
            }
        }

        return URL(fileURLWithPath: template).standardized
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
