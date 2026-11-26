import Foundation
import Darwin

public final class PackageScanner {
    private let fileManager: FileManager
    private let receiptReader: ReceiptReading
    private let safetyGuard: SafetyGuard
    private let privilegeHandler: PrivilegeHandling
    private let customHomeDirectory: URL?

    private static let collapsibleBundleExtensions: Set<String> = [
        "app", "jdk", "framework", "kext", "dext", "prefpane",
        "plugin", "bundle", "saver", "qlgenerator", "mdimporter",
        "xpc", "appex"
    ]

    public init(
        fileManager: FileManager = .default,
        receiptReader: ReceiptReading = ReceiptReader.shared,
        safetyGuard: SafetyGuard? = nil,
        privilegeHandler: PrivilegeHandling = PrivilegeHandler.shared,
        customHomeDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.receiptReader = receiptReader
        self.privilegeHandler = privilegeHandler
        self.customHomeDirectory = customHomeDirectory
        self.safetyGuard = safetyGuard ?? SafetyGuard(fileManager: fileManager, customAllowedRoot: customHomeDirectory)
    }

    /// Scans all files installed by `packageInfo`, checks shared ownership across other receipts,
    /// safely collapses exclusive bundles/directories, and discovers associated runtime leftovers.
    public func scan(
        packageInfo: PackageInfo,
        expandCollapsedDirectories: Bool = false
    ) throws -> PackageScanResult {
        let contents = receiptReader.packageContents(for: packageInfo.packageIdentifier)
        let allReceiptFileSet = Set(contents.files.map { canonicalEntryPath($0) })

        var existingFiles: [URL] = []
        var missingFiles: [URL] = []
        for fileURL in contents.files {
            if pathExistsIncludingSymlink(fileURL.path) {
                existingFiles.append(fileURL)
            } else {
                missingFiles.append(fileURL)
            }
        }

        // Gather safe candidate directories (including packageInfo.baseURL when not root)
        var rawCandidateDirs = contents.directories
        if packageInfo.baseURL.path != "/" {
            rawCandidateDirs.append(packageInfo.baseURL)
        }

        var safeCandidateDirs: [URL] = []
        var seenCandidateDirPaths = Set<String>()
        for dirURL in rawCandidateDirs {
            let stdPath = canonicalEntryPath(dirURL)
            guard seenCandidateDirPaths.insert(stdPath).inserted else { continue }
            guard isDirectory(at: dirURL) else { continue }
            do {
                try safetyGuard.validate(itemURL: dirURL)
                safeCandidateDirs.append(dirURL)
            } catch {
                continue
            }
        }

        // Inspect cross-package shared file & directory ownership
        let ownership = receiptReader.inspectOwnership(
            for: packageInfo.packageIdentifier,
            candidateFiles: existingFiles,
            candidateDirectories: safeCandidateDirs
        )

        var sharedPackageFiles: [SharedPackageFile] = []
        var protectedSkippedPaths: [URL] = []
        var exclusiveValidFiles: [URL] = []

        for fileURL in existingFiles {
            let stdPath = fileURL.standardized.path
            if let otherOwners = ownership.sharedFiles[stdPath] ?? ownership.sharedFiles[canonicalEntryPath(fileURL)], !otherOwners.isEmpty {
                sharedPackageFiles.append(SharedPackageFile(url: fileURL, sharedWithPackages: otherOwners))
                continue
            }
            do {
                try safetyGuard.validate(itemURL: fileURL)
                exclusiveValidFiles.append(fileURL)
            } catch {
                protectedSkippedPaths.append(fileURL)
            }
        }

        let sharedFilePathsSet = Set(sharedPackageFiles.map { canonicalEntryPath($0.url) })
        let exclusiveFilePathsSet = Set(exclusiveValidFiles.map { canonicalEntryPath($0) })
        let dirsWithOtherOwnersCanonical = Set(ownership.directoriesWithOtherOwners.map { canonicalEntryPath(URL(fileURLWithPath: $0)) })

        // Identify exclusive collapsible bundles/directories
        var collapsedDirs: [URL] = []
        var collapsedDirPaths: [String] = []

        if !expandCollapsedDirectories {
            let sortedDirs = safeCandidateDirs.sorted {
                $0.pathComponents.count < $1.pathComponents.count
            }

            for dirURL in sortedDirs {
                let dirPath = canonicalEntryPath(dirURL)
                let dirPrefix = dirPath + "/"

                // Skip if already covered by a collapsed ancestor directory
                if collapsedDirPaths.contains(where: { dirPath == $0 || dirPath.hasPrefix($0 + "/") }) {
                    continue
                }
                // Never collapse if another package owns any file/entry inside this directory
                if dirsWithOtherOwnersCanonical.contains(dirPath) || ownership.directoriesWithOtherOwners.contains(dirURL.standardized.path) {
                    continue
                }
                // Never collapse if any shared file or safety-protected skipped file resides inside
                if sharedFilePathsSet.contains(where: { $0.hasPrefix(dirPrefix) }) {
                    continue
                }
                if protectedSkippedPaths.contains(where: { canonicalEntryPath($0).hasPrefix(dirPrefix) }) {
                    continue
                }
                // Must actually own at least one removable file inside
                guard exclusiveFilePathsSet.contains(where: { $0.hasPrefix(dirPrefix) }) else {
                    continue
                }

                let ext = dirURL.pathExtension.lowercased()
                let isKnownBundle = Self.collapsibleBundleExtensions.contains(ext)
                if isKnownBundle || directoryContainsOnlyReceiptFiles(dirURL, receiptFilePaths: allReceiptFileSet) {
                    collapsedDirs.append(dirURL)
                    collapsedDirPaths.append(dirPath)
                }
            }
        }

        var items: [LeftoverItem] = []
        var seenCanonicalPaths = Set<String>()

        // Add collapsed directories first
        for dirURL in collapsedDirs {
            let canonical = dirURL.resolvingSymlinksInPath().standardized.path
            guard seenCanonicalPaths.insert(canonical).inserted else { continue }
            let size = itemSize(at: dirURL)
            let category = categorizePackageItem(url: dirURL, isDirectory: true)
            items.append(LeftoverItem(
                url: dirURL,
                sizeBytes: size,
                category: category,
                confidence: .high,
                matchReason: "Installed by package \(packageInfo.packageIdentifier)",
                requiresPrivilege: itemRequiresPrivilege(dirURL)
            ))
        }

        // Add remaining individual files not covered by collapsed directories
        for fileURL in exclusiveValidFiles {
            let stdPath = canonicalEntryPath(fileURL)
            if collapsedDirPaths.contains(where: { stdPath.hasPrefix($0 + "/") }) {
                continue
            }
            let canonical = fileURL.resolvingSymlinksInPath().standardized.path
            guard seenCanonicalPaths.insert(canonical).inserted else { continue }
            let size = itemSize(at: fileURL)
            let category = categorizePackageItem(url: fileURL, isDirectory: false)
            items.append(LeftoverItem(
                url: fileURL,
                sizeBytes: size,
                category: category,
                confidence: .high,
                matchReason: "Installed by package \(packageInfo.packageIdentifier)",
                requiresPrivilege: itemRequiresPrivilege(fileURL)
            ))
        }

        // Candidate empty directories for post-removal pruning (deepest first, excluding collapsed dirs)
        let candidateEmptyDirs = safeCandidateDirs
            .filter { dirURL in
                let stdPath = canonicalEntryPath(dirURL)
                return !collapsedDirPaths.contains(where: { stdPath == $0 || stdPath.hasPrefix($0 + "/") })
            }
            .sorted { $0.pathComponents.count > $1.pathComponents.count }

        // Discover any .app bundles owned exclusively by this package
        let appResolver = AppResolver(fileManager: fileManager, receiptReader: receiptReader, customSearchDirectories: [])
        var discoveredAppBundles: [AppInfo] = []
        var seenAppPaths = Set<String>()

        let potentialAppURLs = (collapsedDirs + safeCandidateDirs).filter { dirURL in
            guard dirURL.pathExtension.lowercased() == "app" else { return false }
            let stdPath = canonicalEntryPath(dirURL)
            let prefix = stdPath + "/"
            return !dirsWithOtherOwnersCanonical.contains(stdPath) &&
                   !ownership.directoriesWithOtherOwners.contains(dirURL.standardized.path) &&
                   !sharedFilePathsSet.contains(where: { $0.hasPrefix(prefix) })
        }

        for appURL in potentialAppURLs {
            // Confirm this package actually owns files inside the .app
            let appPrefix = canonicalEntryPath(appURL) + "/"
            guard exclusiveFilePathsSet.contains(where: { $0.hasPrefix(appPrefix) }) else { continue }
            let canonicalApp = appURL.resolvingSymlinksInPath().standardized.path
            guard seenAppPaths.insert(canonicalApp).inserted else { continue }
            if let appInfo = try? appResolver.parseAppBundle(at: appURL, includeReceipts: false) {
                discoveredAppBundles.append(appInfo)
            }
        }

        // Scan runtime leftovers (Preferences, Caches, Application Support, LaunchAgents, etc.)
        let leftoverScanner = LeftoverScanner(
            fileManager: fileManager,
            safetyGuard: safetyGuard,
            customHomeDirectory: customHomeDirectory
        )

        var leftoverTargets = discoveredAppBundles
        if leftoverTargets.isEmpty {
            let syntheticVendor = appResolver.extractVendorToken(from: packageInfo.packageIdentifier)
            leftoverTargets.append(AppInfo(
                bundleURL: packageInfo.baseURL,
                bundleIdentifier: packageInfo.packageIdentifier,
                bundleName: "",
                displayName: packageInfo.displayName,
                executableName: nil,
                vendorToken: syntheticVendor,
                version: packageInfo.version,
                bundleSizeBytes: 0,
                isSystemApp: packageInfo.isProtectedSystemPackage
            ))
        }

        for targetApp in leftoverTargets {
            if let leftoverScan = try? leftoverScanner.scan(appInfo: targetApp) {
                for leftover in leftoverScan.leftovers {
                    let stdPath = leftover.url.standardized.path
                    if sharedFilePathsSet.contains(stdPath) { continue }
                    let canonical = leftover.url.resolvingSymlinksInPath().standardized.path
                    guard seenCanonicalPaths.insert(canonical).inserted else { continue }
                    items.append(leftover)
                }
            }
        }

        // Sort: High confidence first, package items before runtime leftovers within same confidence, then size descending
        items.sort { lhs, rhs in
            if lhs.confidence != rhs.confidence {
                return lhs.confidence > rhs.confidence
            }
            let lhsIsPkg = lhs.category.hasPrefix("Package ")
            let rhsIsPkg = rhs.category.hasPrefix("Package ")
            if lhsIsPkg != rhsIsPkg {
                return lhsIsPkg
            }
            return lhs.sizeBytes > rhs.sizeBytes
        }

        return PackageScanResult(
            packageInfo: packageInfo,
            items: items,
            sharedFiles: sharedPackageFiles.sorted { $0.url.path < $1.url.path },
            missingFilePaths: missingFiles,
            protectedSkippedPaths: protectedSkippedPaths,
            candidateEmptyDirectories: candidateEmptyDirs,
            discoveredAppBundles: discoveredAppBundles
        )
    }

    // MARK: - Helpers

    private func pathExistsIncludingSymlink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    private func isDirectory(at url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    private func canonicalEntryPath(_ url: URL) -> String {
        let std = url.standardized
        let parentCanonical = std.deletingLastPathComponent().resolvingSymlinksInPath().standardized
        return parentCanonical.appendingPathComponent(std.lastPathComponent).standardized.path
    }

    private func directoryContainsOnlyReceiptFiles(_ dirURL: URL, receiptFilePaths: Set<String>) -> Bool {
        guard let enumerator = fileManager.enumerator(
            at: dirURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return false
        }

        var count = 0
        for case let child as URL in enumerator {
            count += 1
            if count > 10_000 {
                return false
            }
            if child.lastPathComponent == ".DS_Store" { continue }
            let vals = try? child.resourceValues(forKeys: [.isDirectoryKey])
            if vals?.isDirectory == true { continue }
            if !receiptFilePaths.contains(canonicalEntryPath(child)) {
                return false
            }
        }
        return true
    }

    private func categorizePackageItem(url: URL, isDirectory: Bool) -> String {
        let ext = url.pathExtension.lowercased()
        let path = url.path

        if ext == "app" {
            return "Package Application Bundles"
        }
        if isDirectory && Self.collapsibleBundleExtensions.contains(ext) {
            return "Package Bundles & Extensions"
        }
        if path.contains("/LaunchAgents/") || path.contains("/LaunchDaemons/") || path.contains("/PrivilegedHelperTools/") {
            return "Package Launch Services"
        }
        if path.hasPrefix("/usr/local/") || path.hasPrefix("/opt/") {
            return "Package Binaries & Files"
        }
        return "Package Files"
    }

    private func itemRequiresPrivilege(_ url: URL) -> Bool {
        if customHomeDirectory != nil {
            return false
        }
        return !privilegeHandler.canWrite(to: url)
    }

    private func itemSize(at url: URL) -> Int64 {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return 0 }
        let fileType = st.st_mode & S_IFMT
        if fileType == S_IFLNK || fileType != S_IFDIR {
            return Int64(st.st_size)
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []
        ) else {
            return 0
        }

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
