import Foundation
import Darwin

public struct PackageOwnershipReport: Equatable {
    /// Maps standardized path -> other package IDs that also own it.
    public let sharedFiles: [String: [String]]
    /// Standardized directory paths where at least one other package owns an entry inside or at the directory.
    public let directoriesWithOtherOwners: Set<String>

    public init(sharedFiles: [String: [String]] = [:], directoriesWithOtherOwners: Set<String> = []) {
        self.sharedFiles = sharedFiles
        self.directoriesWithOtherOwners = directoriesWithOtherOwners
    }
}

public protocol ReceiptReading {
    func allPackages() -> [String]
    func packageInfo(for pkgID: String, includeGroups: Bool) -> PackageInfo?
    func packageContents(for pkgID: String) -> PackageContents
    func inspectOwnership(for pkgID: String, candidateFiles: [URL], candidateDirectories: [URL]) -> PackageOwnershipReport
    func forgetPackage(_ pkgID: String) throws

    // Legacy app-receipt helpers
    func findPackages(matching bundleID: String, appName: String) -> [String]
    func filesForPackage(_ pkgID: String) -> [URL]
}

public extension ReceiptReading {
    func packageInfo(for pkgID: String) -> PackageInfo? {
        return packageInfo(for: pkgID, includeGroups: false)
    }
}

public final class ReceiptReader: ReceiptReading {
    public static let shared = ReceiptReader()

    private let privilegeHandler: PrivilegeHandling
    private let lock = NSLock()
    private var cachedPackages: [String]?
    private var cachedInfos: [String: PackageInfo] = [:]
    private var cachedContents: [String: PackageContents] = [:]
    private var cachedAllEntries: [String: [String]] = [:]

    public init(privilegeHandler: PrivilegeHandling = PrivilegeHandler.shared) {
        self.privilegeHandler = privilegeHandler
    }

    /// Returns all installed package IDs from `pkgutil --pkgs`.
    public func allPackages() -> [String] {
        lock.lock()
        if let cached = cachedPackages {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let output = runCommand("/usr/sbin/pkgutil", ["--pkgs"])
        guard !output.isEmpty else { return [] }
        let packages = output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        lock.lock()
        cachedPackages = packages
        lock.unlock()
        return packages
    }

    /// Reads package receipt metadata, preferring `/var/db/receipts/<pkgID>.plist` for speed unless groups are requested.
    public func packageInfo(for pkgID: String, includeGroups: Bool = false) -> PackageInfo? {
        lock.lock()
        let cached = cachedInfos[pkgID]
        lock.unlock()
        if let cached = cached, (!includeGroups || !cached.groups.isEmpty) {
            return cached
        }

        let receiptPlistURL = URL(fileURLWithPath: "/var/db/receipts/\(pkgID).plist")
        var receiptFilename: String?
        var fastInfo: PackageInfo?

        if let data = try? Data(contentsOf: receiptPlistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            receiptFilename = plist["PackageFileName"] as? String
            let id = plist["PackageIdentifier"] as? String ?? pkgID
            let version = plist["PackageVersion"] as? String
            let installLoc = plist["InstallPrefixPath"] as? String ?? "/"
            let installDate = plist["InstallDate"] as? Date
            fastInfo = PackageInfo(
                packageIdentifier: id,
                version: version,
                volume: "/",
                installLocation: installLoc,
                installTime: installDate,
                packageFileName: receiptFilename,
                groups: []
            )
        }

        if let info = fastInfo, !includeGroups {
            lock.lock()
            cachedInfos[pkgID] = info
            lock.unlock()
            return info
        }

        // Query pkgutil --pkg-info-plist for authoritative volume, location, and groups
        let xmlOutput = runCommand("/usr/sbin/pkgutil", ["--pkg-info-plist", pkgID])
        if let data = xmlOutput.data(using: .utf8),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            let id = plist["pkgid"] as? String ?? pkgID
            let version = plist["pkg-version"] as? String ?? fastInfo?.version
            let volume = plist["volume"] as? String ?? "/"
            let installLocation = plist["install-location"] as? String ?? fastInfo?.installLocation ?? "/"
            let groups = plist["groups"] as? [String] ?? []

            var installTime: Date? = fastInfo?.installTime
            if let epoch = plist["install-time"] as? TimeInterval {
                installTime = Date(timeIntervalSince1970: epoch)
            } else if let epochInt = plist["install-time"] as? Int {
                installTime = Date(timeIntervalSince1970: TimeInterval(epochInt))
            }

            let info = PackageInfo(
                packageIdentifier: id,
                version: version,
                volume: volume,
                installLocation: installLocation,
                installTime: installTime,
                packageFileName: receiptFilename,
                groups: groups
            )
            lock.lock()
            cachedInfos[pkgID] = info
            lock.unlock()
            return info
        }

        if let info = fastInfo {
            lock.lock()
            cachedInfos[pkgID] = info
            lock.unlock()
        }
        return fastInfo
    }

    /// Resolves non-directory entries (files & symlinks) and directory entries installed by `pkgID`.
    public func packageContents(for pkgID: String) -> PackageContents {
        lock.lock()
        if let cached = cachedContents[pkgID] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let info = packageInfo(for: pkgID) else {
            return PackageContents(files: [], directories: [])
        }

        let baseURL = info.baseURL
        let allEntries = rawFileEntries(for: pkgID)
        let dirOutput = runCommand("/usr/sbin/pkgutil", ["--only-dirs", "--files", pkgID])

        var dirPathsSet = Set<String>()
        var directories: [URL] = []
        var seenDirs = Set<String>()

        for line in dirOutput.split(separator: "\n") {
            guard let resolved = resolveRelativeEntry(String(line), baseURL: baseURL) else { continue }
            let path = resolved.standardized.path
            dirPathsSet.insert(path)
            if seenDirs.insert(path).inserted {
                directories.append(resolved)
            }
        }

        var files: [URL] = []
        var seenFiles = Set<String>()
        for entry in allEntries {
            guard let resolved = resolveRelativeEntry(entry, baseURL: baseURL) else { continue }
            let path = resolved.standardized.path
            if !dirPathsSet.contains(path) && seenFiles.insert(path).inserted {
                files.append(resolved)
            }
        }

        let result = PackageContents(files: files, directories: directories)
        lock.lock()
        cachedContents[pkgID] = result
        lock.unlock()
        return result
    }

    /// Checks whether candidate files or directories overlap with any OTHER installed package receipt.
    public func inspectOwnership(for pkgID: String, candidateFiles: [URL], candidateDirectories: [URL]) -> PackageOwnershipReport {
        // Fast path for small packages: query `pkgutil --file-info-plist` concurrently on candidate files
        if candidateFiles.count <= 20 && candidateDirectories.count <= 10 {
            let resultLock = NSLock()
            var sharedFiles: [String: [String]] = [:]
            let group = DispatchGroup()
            let semaphore = DispatchSemaphore(value: 8)
            let queue = DispatchQueue(label: "sweep.pkgutil.fileinfo", attributes: .concurrent)

            for fileURL in candidateFiles {
                group.enter()
                queue.async {
                    semaphore.wait()
                    defer {
                        semaphore.signal()
                        group.leave()
                    }
                    let owners = self.queryFileOwners(at: fileURL.path).filter { $0 != pkgID }
                    if !owners.isEmpty {
                        resultLock.lock()
                        sharedFiles[fileURL.standardized.path] = owners.sorted()
                        resultLock.unlock()
                    }
                }
            }
            group.wait()

            // For candidate directories in fast path, check if any other package's baseURL sits inside or overlaps,
            // and verify all files on disk inside candidateDirectories are not shared if <= 25 total files
            var dirsWithOtherOwners = Set<String>()
            if !candidateDirectories.isEmpty {
                var extraFilesToCheck: [(dirPath: String, filePath: String)] = []
                let candidateFileSet = Set(candidateFiles.map { $0.standardized.path })

                for dirURL in candidateDirectories {
                    let dirPath = dirURL.standardized.path
                    // If any file directly in candidateFiles under this dir already had another owner, mark dir
                    if sharedFiles.keys.contains(where: { $0.hasPrefix(dirPath + "/") }) {
                        dirsWithOtherOwners.insert(dirPath)
                        continue
                    }
                    // Also check if another package directly targeted this dir or a subpath as its installLocation
                    for otherPkg in allPackages() where otherPkg != pkgID {
                        if let otherInfo = packageInfo(for: otherPkg) {
                            let otherBase = otherInfo.baseURL.path
                            if otherBase == dirPath || otherBase.hasPrefix(dirPath + "/") {
                                dirsWithOtherOwners.insert(dirPath)
                                break
                            }
                        }
                    }
                    if dirsWithOtherOwners.contains(dirPath) { continue }

                    // Check non-receipt files on disk inside dir (up to small cap)
                    if let enumerator = FileManager.default.enumerator(
                        at: dirURL,
                        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                        options: []
                    ) {
                        for case let child as URL in enumerator {
                            let vals = try? child.resourceValues(forKeys: [.isDirectoryKey])
                            if vals?.isDirectory == true { continue }
                            let childPath = child.standardized.path
                            if !candidateFileSet.contains(childPath) {
                                extraFilesToCheck.append((dirPath, childPath))
                            }
                            if extraFilesToCheck.count > 40 { break }
                        }
                    }
                }

                if extraFilesToCheck.count <= 40 && !extraFilesToCheck.isEmpty {
                    let dirGroup = DispatchGroup()
                    for pair in extraFilesToCheck {
                        dirGroup.enter()
                        queue.async {
                            semaphore.wait()
                            defer {
                                semaphore.signal()
                                dirGroup.leave()
                            }
                            let owners = self.queryFileOwners(at: pair.filePath).filter { $0 != pkgID }
                            if !owners.isEmpty {
                                resultLock.lock()
                                dirsWithOtherOwners.insert(pair.dirPath)
                                resultLock.unlock()
                            }
                        }
                    }
                    dirGroup.wait()
                } else if extraFilesToCheck.count > 40 {
                    // Fall back to bulk scan below if there are many untracked files inside candidate dirs
                    return bulkInspectOwnership(for: pkgID, candidateFiles: candidateFiles, candidateDirectories: candidateDirectories)
                }
            }

            return PackageOwnershipReport(sharedFiles: sharedFiles, directoriesWithOtherOwners: dirsWithOtherOwners)
        }

        return bulkInspectOwnership(for: pkgID, candidateFiles: candidateFiles, candidateDirectories: candidateDirectories)
    }

    private func bulkInspectOwnership(for pkgID: String, candidateFiles: [URL], candidateDirectories: [URL]) -> PackageOwnershipReport {
        let targetFileSet = Set(candidateFiles.map { $0.standardized.path })
        let candidateDirSet = Set(candidateDirectories.map { $0.standardized.path })
        let allCandidatePaths = targetFileSet.union(candidateDirSet)

        let otherPackages = allPackages().filter { $0 != pkgID }
        var overlappingPackages: [(pkgID: String, baseURL: URL)] = []

        for other in otherPackages {
            guard let info = packageInfo(for: other) else { continue }
            let base = info.baseURL
            let basePath = base.path
            if basePath == "/" {
                overlappingPackages.append((other, base))
                continue
            }
            let prefix = basePath + "/"
            let intersects = allCandidatePaths.contains { path in
                path == basePath || path.hasPrefix(prefix) || basePath.hasPrefix(path + "/")
            }
            if intersects {
                overlappingPackages.append((other, base))
            }
        }

        let resultLock = NSLock()
        var sharedFiles: [String: Set<String>] = [:]
        var dirsWithOtherOwners = Set<String>()

        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(value: 8)
        let queue = DispatchQueue(label: "sweep.pkgutil.bulk", attributes: .concurrent)

        for entry in overlappingPackages {
            group.enter()
            queue.async {
                semaphore.wait()
                defer {
                    semaphore.signal()
                    group.leave()
                }

                let rawEntries = self.rawFileEntries(for: entry.pkgID)
                var localShared: [String] = []
                var localDirs = Set<String>()

                for rel in rawEntries {
                    guard let resolved = self.resolveRelativeEntry(rel, baseURL: entry.baseURL) else { continue }
                    let path = resolved.standardized.path

                    if targetFileSet.contains(path) {
                        localShared.append(path)
                    }

                    if !candidateDirSet.isEmpty {
                        // Walk ancestor directories up to root to check if `path` lies inside any candidate directory
                        var probe = resolved.standardized
                        while probe.path != "/" {
                            if candidateDirSet.contains(probe.path) {
                                // Only mark directory if `path` is a strict descendant, or `path` is not just a shared parent dir name
                                if probe.path != path {
                                    localDirs.insert(probe.path)
                                }
                            }
                            let parent = probe.deletingLastPathComponent()
                            if parent.path == probe.path { break }
                            probe = parent
                        }
                    }
                }

                if !localShared.isEmpty || !localDirs.isEmpty {
                    resultLock.lock()
                    for s in localShared {
                        sharedFiles[s, default: []].insert(entry.pkgID)
                    }
                    dirsWithOtherOwners.formUnion(localDirs)
                    resultLock.unlock()
                }
            }
        }

        group.wait()

        let normalizedShared = sharedFiles.mapValues { Array($0).sorted() }
        return PackageOwnershipReport(sharedFiles: normalizedShared, directoriesWithOtherOwners: dirsWithOtherOwners)
    }

    public func forgetPackage(_ pkgID: String) throws {
        try privilegeHandler.forgetPackageReceipt(pkgID)
        lock.lock()
        cachedPackages = nil
        cachedInfos.removeValue(forKey: pkgID)
        cachedContents.removeValue(forKey: pkgID)
        cachedAllEntries.removeValue(forKey: pkgID)
        lock.unlock()
    }

    /// Runs `pkgutil --pkgs` and finds receipts matching the bundle identifier or app name
    public func findPackages(matching bundleID: String, appName: String) -> [String] {
        let all = allPackages()
        let normalizedApp = appName.lowercased()
        let normalizedBundle = bundleID.lowercased()

        return all.filter { line in
            let lower = line.lowercased()
            return lower == normalizedBundle ||
                   lower.contains(normalizedBundle) ||
                   (!normalizedApp.isEmpty && normalizedApp.count > 3 && lower.contains(normalizedApp))
        }
    }

    /// Queries `pkgutil` to resolve existing non-directory absolute file URLs for an app bundle's receipts
    public func filesForPackage(_ pkgID: String) -> [URL] {
        return packageContents(for: pkgID).files.filter { pathExistsIncludingSymlink($0.path) }
    }

    // MARK: - Helpers

    public func pathExistsIncludingSymlink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    private func rawFileEntries(for pkgID: String) -> [String] {
        lock.lock()
        if let cached = cachedAllEntries[pkgID] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let output = runCommand("/usr/sbin/pkgutil", ["--files", pkgID])
        guard !output.isEmpty else { return [] }
        let lines = output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        lock.lock()
        cachedAllEntries[pkgID] = lines
        lock.unlock()
        return lines
    }

    private func queryFileOwners(at path: String) -> [String] {
        let output = runCommand("/usr/sbin/pkgutil", ["--file-info-plist", path])
        guard let data = output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let pathInfo = plist["path-info"] as? [[String: Any]] else {
            return []
        }
        return pathInfo.compactMap { $0["pkgid"] as? String }
    }

    private func resolveRelativeEntry(_ rawEntry: String, baseURL: URL) -> URL? {
        var rel = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        if rel.hasPrefix("./") {
            rel = String(rel.dropFirst(2))
        }
        while rel.hasPrefix("/") {
            rel = String(rel.dropFirst())
        }
        guard !rel.isEmpty, rel != "." else { return nil }
        return baseURL.appendingPathComponent(rel).standardized
    }

    private func runCommand(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
