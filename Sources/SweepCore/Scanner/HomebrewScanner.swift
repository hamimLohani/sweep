import Foundation
import Darwin

public final class HomebrewScanner {
    private let fileManager: FileManager
    private let reader: HomebrewReading
    private let safetyGuard: SafetyGuard
    private let privilegeHandler: PrivilegeHandling
    private let customHomeDirectory: URL?

    public init(
        fileManager: FileManager = .default,
        reader: HomebrewReading = HomebrewReader.shared,
        safetyGuard: SafetyGuard? = nil,
        privilegeHandler: PrivilegeHandling = PrivilegeHandler.shared,
        customHomeDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.reader = reader
        self.privilegeHandler = privilegeHandler
        self.customHomeDirectory = customHomeDirectory
        self.safetyGuard = safetyGuard ?? SafetyGuard(fileManager: fileManager, customAllowedRoot: customHomeDirectory)
    }

    public func scan(packageInfo: HomebrewPackageInfo) throws -> HomebrewScanResult {
        var artifactItems: [LeftoverItem] = []
        var cleanupItems: [LeftoverItem] = []
        var seenCleanupPaths = Set<String>()
        var seenArtifactPaths = Set<String>()

        let cellarSize: Int64
        if let cellarURL = packageInfo.cellarOrCaskroomURL, pathExists(cellarURL.path) {
            cellarSize = calculateSize(of: cellarURL)
        } else {
            cellarSize = 0
        }

        // 1. Installed package artifacts (for casks: .app, binaries, fonts, manpages; for formulas: Cellar linked artifacts)
        let artifactGroups: [(paths: [String], category: String, label: String)] = [
            (packageInfo.artifactAppPaths, "Homebrew App Bundle", "Cask application bundle"),
            (packageInfo.artifactBinaryPaths, "Homebrew Linked Binaries", "Cask binary artifact"),
            (packageInfo.artifactFontPaths, "Homebrew Fonts", "Cask font artifact"),
            (packageInfo.artifactManpagePaths, "Homebrew Manpages", "Cask manpage artifact")
        ]

        let appResolver = AppResolver(fileManager: fileManager, customSearchDirectories: [])
        var discoveredAppBundles: [AppInfo] = []

        for group in artifactGroups {
            for rawPath in group.paths {
                let url = expandPath(rawPath)
                guard pathExists(url.path) else { continue }
                let canonical = canonicalEntryPath(url)
                guard seenArtifactPaths.insert(canonical).inserted else { continue }

                let size = calculateSize(of: url)
                artifactItems.append(LeftoverItem(
                    url: url,
                    sizeBytes: size,
                    category: group.category,
                    confidence: .high,
                    matchReason: "\(group.label) installed by \(packageInfo.fullName)",
                    requiresPrivilege: requiresPrivilege(url)
                ))

                if url.pathExtension.lowercased() == "app",
                   let appInfo = try? appResolver.parseAppBundle(at: url, includeReceipts: false) {
                    discoveredAppBundles.append(appInfo)
                }
            }
        }

        // Helper to validate and append cleanup candidate
        func addCleanupCandidate(url: URL, category: String, confidence: Confidence, reason: String) {
            guard pathExists(url.path) else { return }
            let canonical = canonicalEntryPath(url)
            guard !seenArtifactPaths.contains(canonical) else { return }
            guard !seenCleanupPaths.contains(canonical) else { return }

            do {
                try safetyGuard.validate(itemURL: url)
            } catch {
                return
            }

            let size = calculateSize(of: url)
            seenCleanupPaths.insert(canonical)
            cleanupItems.append(LeftoverItem(
                url: url,
                sizeBytes: size,
                category: category,
                confidence: confidence,
                matchReason: reason,
                requiresPrivilege: requiresPrivilege(url)
            ))
        }

        // 2. Cask zap paths (trash, delete, rmdir)
        for pattern in packageInfo.zapTrashPaths + packageInfo.zapDeletePaths {
            for url in expandPathPattern(pattern) {
                addCleanupCandidate(
                    url: url,
                    category: "Homebrew Cask Zap Data",
                    confidence: .high,
                    reason: "Listed in Homebrew cask zap stanza (\(packageInfo.name))"
                )
            }
        }
        for pattern in packageInfo.zapRmdirPaths {
            for url in expandPathPattern(pattern) {
                if isEmptyDirectory(at: url) {
                    addCleanupCandidate(
                        url: url,
                        category: "Homebrew Cask Zap Data",
                        confidence: .high,
                        reason: "Empty directory listed in cask zap rmdir (\(packageInfo.name))"
                    )
                }
            }
        }

        // 3. LeftoverScanner for cask .app bundles (finds Preferences, Caches, Containers, Saved State, etc.)
        let leftoverScanner = LeftoverScanner(
            fileManager: fileManager,
            safetyGuard: safetyGuard,
            customHomeDirectory: customHomeDirectory
        )
        for appInfo in discoveredAppBundles {
            if let appScan = try? leftoverScanner.scan(appInfo: appInfo) {
                for item in appScan.leftovers {
                    let canonical = canonicalEntryPath(item.url)
                    guard !seenArtifactPaths.contains(canonical), seenCleanupPaths.insert(canonical).inserted else { continue }
                    cleanupItems.append(item)
                }
            }
        }

        // 4. Formula-specific config/data/logs & service plist leftovers
        if packageInfo.kind == .formula {
            let prefixURL = URL(fileURLWithPath: packageInfo.prefixPath)
            let homeDir = customHomeDirectory ?? fileManager.homeDirectoryForCurrentUser

            let formulaEtc = prefixURL.appendingPathComponent("etc/\(packageInfo.name)").standardized
            addCleanupCandidate(
                url: formulaEtc,
                category: "Homebrew Formula Config",
                confidence: .medium,
                reason: "Homebrew etc configuration directory (\(packageInfo.name))"
            )

            let formulaVar = prefixURL.appendingPathComponent("var/\(packageInfo.name)").standardized
            addCleanupCandidate(
                url: formulaVar,
                category: "Homebrew Formula Data",
                confidence: .medium,
                reason: "Homebrew var data directory (\(packageInfo.name))"
            )

            let formulaVarLog = prefixURL.appendingPathComponent("var/log/\(packageInfo.name)").standardized
            addCleanupCandidate(
                url: formulaVarLog,
                category: "Homebrew Formula Logs",
                confidence: .high,
                reason: "Homebrew var/log directory (\(packageInfo.name))"
            )

            let xdgConfig = homeDir.appendingPathComponent(".config/\(packageInfo.name)").standardized
            addCleanupCandidate(
                url: xdgConfig,
                category: "User Config (~/.config)",
                confidence: .medium,
                reason: "XDG configuration directory for \(packageInfo.name)"
            )

            if packageInfo.name.count >= 4 {
                let userAppSupport = homeDir.appendingPathComponent("Library/Application Support/\(packageInfo.name)").standardized
                addCleanupCandidate(
                    url: userAppSupport,
                    category: "Application Support",
                    confidence: .medium,
                    reason: "Application Support folder matching formula name (\(packageInfo.name))"
                )

                let userCaches = homeDir.appendingPathComponent("Library/Caches/\(packageInfo.name)").standardized
                addCleanupCandidate(
                    url: userCaches,
                    category: "User Caches",
                    confidence: .high,
                    reason: "User cache directory matching formula name (\(packageInfo.name))"
                )
            }

            if let svcPlist = packageInfo.servicePlistPath {
                let svcURL = expandPath(svcPlist)
                // Only flag LaunchAgents/LaunchDaemons copy installed by brew services (outside Cellar)
                if !svcURL.path.hasPrefix(prefixURL.appendingPathComponent("opt").path) &&
                   !svcURL.path.hasPrefix(prefixURL.appendingPathComponent("Cellar").path) {
                    addCleanupCandidate(
                        url: svcURL,
                        category: "Homebrew Service Plist",
                        confidence: .high,
                        reason: "Homebrew service launch plist (\(packageInfo.name))"
                    )
                }
            }
        }

        // 5. Homebrew download cache items (~/Library/Caches/Homebrew)
        if let cacheRoot = reader.cacheDirectory(), fileManager.fileExists(atPath: cacheRoot.path) {
            let namesToMatch = Set(([packageInfo.name] + packageInfo.oldNames).filter { !$0.isEmpty })
            let searchDirs = packageInfo.kind == .cask
                ? [cacheRoot, cacheRoot.appendingPathComponent("Cask")]
                : [cacheRoot]

            for dir in searchDirs where fileManager.fileExists(atPath: dir.path) {
                if let rawEntries = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                    for rawEntry in rawEntries {
                        let fname = rawEntry.lastPathComponent
                        let entry = dir.appendingPathComponent(fname).standardized
                        let matchesCache = namesToMatch.contains { token in
                            fname.hasPrefix("\(token)--") || fname.hasPrefix("\(token)_bottle_manifest--")
                        }
                        guard matchesCache else { continue }

                        // If cache entry is a symlink into downloads/, also collect the backing download blob
                        var st = stat()
                        if lstat(entry.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK {
                            let targetURL = entry.resolvingSymlinksInPath().standardized
                            if targetURL.path != entry.standardized.path && pathExists(targetURL.path) {
                                addCleanupCandidate(
                                    url: targetURL,
                                    category: "Homebrew Download Cache",
                                    confidence: .high,
                                    reason: "Cached Homebrew download artifact for \(packageInfo.name)"
                                )
                            }
                        }
                        addCleanupCandidate(
                            url: entry,
                            category: "Homebrew Download Cache",
                            confidence: .high,
                            reason: "Cached Homebrew bottle/cask symlink for \(packageInfo.name)"
                        )
                    }
                }
            }
        }

        // 6. Compute potentially orphaned dependencies (for formulae)
        var orphanedDeps: [String] = []
        if packageInfo.kind == .formula, let allPackages = try? reader.installedPackages() {
            let pkgByName = Dictionary(uniqueKeysWithValues: allPackages.filter { $0.kind == .formula }.map { ($0.name, $0) })
            for depFull in packageInfo.runtimeDependencies {
                let depShort = depFull.split(separator: "/").last.map(String.init) ?? depFull
                guard let depPkg = pkgByName[depShort] else { continue }
                if !depPkg.installedOnRequest {
                    let otherConsumers = depPkg.requiredBy.filter { $0 != packageInfo.name }
                    if otherConsumers.isEmpty {
                        orphanedDeps.append(depPkg.name)
                    }
                }
            }
            orphanedDeps.sort()
        }

        cleanupItems.sort { lhs, rhs in
            if lhs.confidence != rhs.confidence {
                return lhs.confidence > rhs.confidence
            }
            return lhs.sizeBytes > rhs.sizeBytes
        }

        return HomebrewScanResult(
            packageInfo: packageInfo,
            cellarSizeBytes: cellarSize,
            artifactItems: artifactItems,
            cleanupItems: cleanupItems,
            discoveredAppBundles: discoveredAppBundles,
            orphanedDependencies: orphanedDeps
        )
    }

    /// Computes total on-disk bytes for each Homebrew formula/cask concurrently (Cellar/Caskroom + installed cask artifacts).
    public func installedSizes(for packages: [HomebrewPackageInfo]) -> [String: Int64] {
        guard !packages.isEmpty else { return [:] }

        let resultLock = NSLock()
        var sizes: [String: Int64] = [:]
        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(value: 8)
        let queue = DispatchQueue(label: "sweep.brew.sizes", attributes: .concurrent)

        for pkg in packages {
            group.enter()
            queue.async {
                semaphore.wait()
                defer {
                    semaphore.signal()
                    group.leave()
                }
                let size = self.installedSizeBytes(for: pkg)
                let key = Self.sizeKey(for: pkg)
                resultLock.lock()
                sizes[key] = size
                resultLock.unlock()
            }
        }

        group.wait()
        return sizes
    }

    public static func sizeKey(for pkg: HomebrewPackageInfo) -> String {
        return "\(pkg.kind.rawValue):\(pkg.fullName)"
    }

    public func installedSizeBytes(for pkg: HomebrewPackageInfo) -> Int64 {
        var total: Int64 = 0
        var seenCanonical = Set<String>()

        if let cellarURL = pkg.cellarOrCaskroomURL, pathExists(cellarURL.path) {
            seenCanonical.insert(canonicalEntryPath(cellarURL))
            total += calculateSize(of: cellarURL)
        }

        if pkg.kind == .cask {
            let artifactPaths = pkg.artifactAppPaths + pkg.artifactBinaryPaths + pkg.artifactFontPaths + pkg.artifactManpagePaths
            for rawPath in artifactPaths {
                let url = expandPath(rawPath)
                guard pathExists(url.path) else { continue }
                let canonical = canonicalEntryPath(url)
                guard seenCanonical.insert(canonical).inserted else { continue }
                total += calculateSize(of: url)
            }
        }

        return total
    }

    // MARK: - Helpers

    private func expandPath(_ raw: String) -> URL {
        if raw.hasPrefix("~/") {
            let home = customHomeDirectory ?? fileManager.homeDirectoryForCurrentUser
            return home.appendingPathComponent(String(raw.dropFirst(2))).standardized
        }
        if raw == "~" {
            return (customHomeDirectory ?? fileManager.homeDirectoryForCurrentUser).standardized
        }
        return URL(fileURLWithPath: raw).standardized
    }

    private func expandPathPattern(_ pattern: String) -> [URL] {
        guard pattern.contains("*") || pattern.contains("?") else {
            return [expandPath(pattern)]
        }

        let expanded = expandPath(pattern)
        let parentDir = expanded.deletingLastPathComponent()
        let filePattern = expanded.lastPathComponent

        // Only expand simple filename wildcards inside a concrete parent directory (never wildcarding parent components)
        guard !parentDir.path.contains("*"), !parentDir.path.contains("?"), fileManager.fileExists(atPath: parentDir.path) else {
            return []
        }

        guard let entries = try? fileManager.contentsOfDirectory(at: parentDir, includingPropertiesForKeys: nil) else {
            return []
        }

        return entries.compactMap { entry in
            let name = entry.lastPathComponent
            guard fnmatch(filePattern, name, 0) == 0 else { return nil }
            return parentDir.appendingPathComponent(name).standardized
        }
    }

    private func pathExists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    private func isEmptyDirectory(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        return (try? fileManager.contentsOfDirectory(atPath: url.path))?.isEmpty ?? false
    }

    private func canonicalEntryPath(_ url: URL) -> String {
        let std = url.standardized
        let parentCanonical = std.deletingLastPathComponent().resolvingSymlinksInPath().standardized
        return parentCanonical.appendingPathComponent(std.lastPathComponent).standardized.path
    }

    private func requiresPrivilege(_ url: URL) -> Bool {
        if customHomeDirectory != nil {
            return false
        }
        return !privilegeHandler.canWrite(to: url)
    }

    private func calculateSize(of url: URL) -> Int64 {
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
            guard let vals = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  vals.isRegularFile == true,
                  let size = vals.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }
}
