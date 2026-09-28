import Foundation

public final class AppResolver {
    private let fileManager: FileManager
    private let receiptReader: ReceiptReading
    private let applicationDirectories: [URL]

    public init(
        fileManager: FileManager = .default,
        receiptReader: ReceiptReading = ReceiptReader.shared,
        customSearchDirectories: [URL]? = nil
    ) {
        self.fileManager = fileManager
        self.receiptReader = receiptReader

        if let customDirs = customSearchDirectories {
            self.applicationDirectories = customDirs
        } else {
            var dirs = [URL(fileURLWithPath: "/Applications")]
            let userApps = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
            if fileManager.fileExists(atPath: userApps.path) {
                dirs.append(userApps)
            }
            self.applicationDirectories = dirs
        }
    }

    /// Resolves an application from a name, a path to .app, or a bundle identifier.
    public func resolve(target: String) throws -> AppInfo {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SweepError.invalidPath(target)
        }

        // Case 1: Check if target is an existing path to a .app bundle
        let targetURL = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardized
        if targetURL.pathExtension == "app" && fileManager.fileExists(atPath: targetURL.path) {
            return try parseAppBundle(at: targetURL)
        }

        // Case 2: Discover all installed applications and search by bundle ID or name
        let installedApps = listInstalledApps()

        // 2A: Exact Bundle ID match
        if let match = installedApps.first(where: { $0.bundleIdentifier.lowercased() == trimmed.lowercased() }) {
            return match
        }

        // 2B: Exact Name match (e.g. "Slack" or "Slack.app")
        let targetName = trimmed.hasSuffix(".app") ? String(trimmed.dropLast(4)) : trimmed
        if let match = installedApps.first(where: {
            $0.bundleName.lowercased() == targetName.lowercased() ||
            $0.displayName.lowercased() == targetName.lowercased() ||
            $0.bundleURL.deletingPathExtension().lastPathComponent.lowercased() == targetName.lowercased()
        }) {
            return match
        }

        // 2C: Case-insensitive prefix/contains match as fallback
        if let match = installedApps.first(where: {
            $0.bundleName.localizedCaseInsensitiveContains(targetName) ||
            $0.displayName.localizedCaseInsensitiveContains(targetName)
        }) {
            return match
        }

        throw SweepError.appNotFound(target)
    }

    /// Lists all installed applications in the configured search directories.
    public func listInstalledApps() -> [AppInfo] {
        var foundApps: [AppInfo] = []

        for dir in applicationDirectories {
            guard fileManager.fileExists(atPath: dir.path) else { continue }
            discoverApps(in: dir, currentDepth: 0, maxDepth: 2, results: &foundApps)
        }

        return foundApps.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func discoverApps(in directory: URL, currentDepth: Int, maxDepth: Int, results: inout [AppInfo]) {
        guard currentDepth <= maxDepth else { return }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for item in contents {
            if item.pathExtension == "app" {
                if let appInfo = try? parseAppBundle(at: item, includeReceipts: false) {
                    results.append(appInfo)
                }
            } else {
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                    // Do not recurse into .framework or .plugin or System extensions
                    if !["framework", "plugin", "bundle", "kext"].contains(item.pathExtension) {
                        discoverApps(in: item, currentDepth: currentDepth + 1, maxDepth: maxDepth, results: &results)
                    }
                }
            }
        }
    }

    /// Parses the Info.plist and gathers bundle size and receipt data.
    public func parseAppBundle(at bundleURL: URL, includeReceipts: Bool = true) throws -> AppInfo {
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard fileManager.fileExists(atPath: plistURL.path) else {
            throw SweepError.appNotFound("Info.plist missing in \(bundleURL.path)")
        }

        guard let plistData = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            throw SweepError.appNotFound("Corrupt or unreadable Info.plist in \(bundleURL.path)")
        }

        let bundleIdentifier = plist["CFBundleIdentifier"] as? String ?? ""
        let bundleName = plist["CFBundleName"] as? String ?? bundleURL.deletingPathExtension().lastPathComponent
        let displayName = plist["CFBundleDisplayName"] as? String ?? bundleName
        let executableName = plist["CFBundleExecutable"] as? String
        let version = plist["CFBundleShortVersionString"] as? String ?? plist["CFBundleVersion"] as? String

        let vendor = extractVendorToken(from: bundleIdentifier)
        let isSystem = bundleURL.path.hasPrefix("/System/") || bundleIdentifier.hasPrefix("com.apple.")
        let size = isSystem ? 0 : calculateSize(of: bundleURL)

        let packages = (includeReceipts && !isSystem) ? receiptReader.findPackages(matching: bundleIdentifier, appName: bundleName) : []
        var receiptFiles: [URL] = []
        if includeReceipts && !isSystem {
            for pkg in packages {
                receiptFiles.append(contentsOf: receiptReader.filesForPackage(pkg))
            }
        }

        return AppInfo(
            bundleURL: bundleURL,
            bundleIdentifier: bundleIdentifier,
            bundleName: bundleName,
            displayName: displayName,
            executableName: executableName,
            vendorToken: vendor,
            version: version,
            bundleSizeBytes: size,
            isSystemApp: isSystem,
            receiptPackages: packages,
            receiptFiles: receiptFiles
        )
    }

    /// Extracts vendor token from reverse-DNS bundle identifier (e.g. com.tinyspeck.slackmacgap -> tinyspeck).
    public func extractVendorToken(from bundleID: String) -> String? {
        let genericPrefixes: Set<String> = ["com", "org", "net", "io", "co", "app", "dev", "mac", "me", "us", "uk", "de", "fr"]
        let parts = bundleID.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return nil }

        for part in parts {
            let lower = part.lowercased()
            if !genericPrefixes.contains(lower) && lower.count >= 3 {
                return lower
            }
        }
        return nil
    }

    /// Recursively calculates the byte size of a file or directory bundle.
    public func calculateSize(of url: URL) -> Int64 {
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
