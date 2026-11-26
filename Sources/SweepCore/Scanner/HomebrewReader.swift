import Foundation

public struct HomebrewServiceStatus: Codable, Equatable {
    public let name: String
    public let status: String
    public let user: String?
    public let file: String?

    public var isRunning: Bool {
        let lower = status.lowercased()
        return lower == "started" || lower == "running"
    }
}

public protocol HomebrewReading {
    func isAvailable() -> Bool
    func brewExecutablePath() -> String?
    func brewPrefix() -> String
    func cacheDirectory() -> URL?
    func brewVersion() -> String?
    func installedPackages() throws -> [HomebrewPackageInfo]
    func runningServices() -> [String: HomebrewServiceStatus]
    func stopService(_ name: String) throws
    func uninstall(package: HomebrewPackageInfo, ignoreDependencies: Bool, force: Bool) throws -> String
    func autoremove(dryRun: Bool) throws -> String
}

public final class HomebrewReader: HomebrewReading {
    public static let shared = HomebrewReader()

    private let fileManager: FileManager
    private let lock = NSLock()
    private var cachedBrewPath: String?
    private var cachedPrefix: String?
    private var cachedCacheDir: URL?

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func brewExecutablePath() -> String? {
        lock.lock()
        if let cached = cachedBrewPath {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let standardCandidates = [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew"
        ]
        for path in standardCandidates where fileManager.isExecutableFile(atPath: path) {
            lock.lock()
            cachedBrewPath = path
            lock.unlock()
            return path
        }

        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("brew").path
                if fileManager.isExecutableFile(atPath: candidate) {
                    lock.lock()
                    cachedBrewPath = candidate
                    lock.unlock()
                    return candidate
                }
            }
        }
        return nil
    }

    public func isAvailable() -> Bool {
        return brewExecutablePath() != nil
    }

    public func brewPrefix() -> String {
        lock.lock()
        if let cached = cachedPrefix {
            lock.unlock()
            return cached
        }
        lock.unlock()

        if let brew = brewExecutablePath() {
            let res = runBrew(brew, ["--prefix"])
            let trimmed = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if res.status == 0 && !trimmed.isEmpty {
                lock.lock()
                cachedPrefix = trimmed
                lock.unlock()
                return trimmed
            }
            if brew.hasPrefix("/opt/homebrew/") { return "/opt/homebrew" }
            if brew.hasPrefix("/usr/local/") { return "/usr/local" }
        }

        return fileManager.fileExists(atPath: "/opt/homebrew") ? "/opt/homebrew" : "/usr/local"
    }

    public func cacheDirectory() -> URL? {
        lock.lock()
        if let cached = cachedCacheDir {
            lock.unlock()
            return cached
        }
        lock.unlock()

        if let brew = brewExecutablePath() {
            let res = runBrew(brew, ["--cache"])
            let trimmed = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if res.status == 0 && !trimmed.isEmpty {
                let url = URL(fileURLWithPath: trimmed).standardized
                lock.lock()
                cachedCacheDir = url
                lock.unlock()
                return url
            }
        }

        let fallback = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Homebrew")
        return fileManager.fileExists(atPath: fallback.path) ? fallback : nil
    }

    public func brewVersion() -> String? {
        guard let brew = brewExecutablePath() else { return nil }
        let res = runBrew(brew, ["--version"])
        guard res.status == 0 else { return nil }
        return res.stdout.split(separator: "\n").first.map(String.init)
    }

    public func runningServices() -> [String: HomebrewServiceStatus] {
        guard let brew = brewExecutablePath() else { return [:] }
        let res = runBrew(brew, ["services", "list", "--json"])
        guard res.status == 0,
              let data = res.stdout.data(using: .utf8),
              let services = try? JSONDecoder().decode([HomebrewServiceStatus].self, from: data) else {
            return [:]
        }
        var map: [String: HomebrewServiceStatus] = [:]
        for svc in services {
            map[svc.name] = svc
        }
        return map
    }

    public func installedPackages() throws -> [HomebrewPackageInfo] {
        guard let brew = brewExecutablePath() else {
            throw SweepError.general("Homebrew (brew) is not installed or could not be found in /opt/homebrew/bin, /usr/local/bin, or PATH.")
        }

        let res = runBrew(brew, ["info", "--json=v2", "--installed"])
        guard res.status == 0, let data = res.stdout.data(using: .utf8) else {
            let errText = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SweepError.executionFailed("Failed to query Homebrew installed packages: \(errText.isEmpty ? "exit \(res.status)" : errText)")
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SweepError.executionFailed("Failed to parse JSON output from 'brew info --json=v2 --installed'.")
        }

        let prefix = brewPrefix()
        let services = runningServices()

        let rawFormulae = root["formulae"] as? [[String: Any]] ?? []
        let rawCasks = root["casks"] as? [[String: Any]] ?? []

        // Build reverse dependency map from installed formulae's runtime_dependencies + dependencies
        var requiredByMap: [String: Set<String>] = [:]
        for f in rawFormulae {
            guard let consumerName = f["name"] as? String else { continue }
            let installedEntries = f["installed"] as? [[String: Any]] ?? []
            var depNames = Set<String>()
            if let latest = installedEntries.last,
               let runtimeDeps = latest["runtime_dependencies"] as? [[String: Any]] {
                for dep in runtimeDeps {
                    if let fullDep = dep["full_name"] as? String {
                        let shortDep = fullDep.split(separator: "/").last.map(String.init) ?? fullDep
                        depNames.insert(shortDep)
                    }
                }
            }
            if depNames.isEmpty, let declaredDeps = f["dependencies"] as? [String] {
                for dep in declaredDeps {
                    let shortDep = dep.split(separator: "/").last.map(String.init) ?? dep
                    depNames.insert(shortDep)
                }
            }
            for dep in depNames where dep != consumerName {
                requiredByMap[dep, default: []].insert(consumerName)
            }
        }
        // Also count casks that declare formula dependencies
        for c in rawCasks {
            guard let caskToken = c["token"] as? String else { continue }
            if let dependsOn = c["depends_on"] as? [String: Any],
               let formulaDeps = dependsOn["formula"] as? [String] {
                for dep in formulaDeps {
                    let shortDep = dep.split(separator: "/").last.map(String.init) ?? dep
                    requiredByMap[shortDep, default: []].insert("\(caskToken) (cask)")
                }
            }
        }

        var packages: [HomebrewPackageInfo] = []

        for f in rawFormulae {
            guard let name = f["name"] as? String else { continue }
            let fullName = f["full_name"] as? String ?? name
            let tap = f["tap"] as? String ?? "homebrew/core"
            let desc = f["desc"] as? String
            let homepage = f["homepage"] as? String
            let aliases = f["aliases"] as? [String] ?? []
            let oldNames = f["oldnames"] as? [String] ?? []
            let pinned = f["pinned"] as? Bool ?? false
            let outdated = f["outdated"] as? Bool ?? false
            let kegOnly = f["keg_only"] as? Bool ?? false
            let dependencies = f["dependencies"] as? [String] ?? []

            let installedList = f["installed"] as? [[String: Any]] ?? []
            let activeInstalled = installedList.last
            let linkedKeg = f["linked_keg"] as? String
            let version = linkedKeg ?? (activeInstalled?["version"] as? String) ?? "unknown"
            let installedOnRequest = activeInstalled?["installed_on_request"] as? Bool ?? true

            var installedTime: Date?
            if let epoch = activeInstalled?["time"] as? TimeInterval {
                installedTime = Date(timeIntervalSince1970: epoch)
            } else if let epochInt = activeInstalled?["time"] as? Int {
                installedTime = Date(timeIntervalSince1970: TimeInterval(epochInt))
            }

            var runtimeDeps: [String] = []
            if let rdeps = activeInstalled?["runtime_dependencies"] as? [[String: Any]] {
                runtimeDeps = rdeps.compactMap { $0["full_name"] as? String }
            }

            let cellarDir = URL(fileURLWithPath: prefix).appendingPathComponent("Cellar/\(name)").standardized
            let hasServiceDef = !(f["service"] is NSNull) && f["service"] != nil
            let svcStatus = services[name]
            let serviceName = hasServiceDef || svcStatus != nil ? (svcStatus?.name ?? name) : nil

            let reqBy = Array(requiredByMap[name] ?? []).sorted()

            packages.append(HomebrewPackageInfo(
                name: name,
                fullName: fullName,
                kind: .formula,
                tap: tap,
                version: version,
                installedTime: installedTime,
                descriptionText: desc,
                homepage: homepage,
                prefixPath: prefix,
                cellarOrCaskroomURL: fileManager.fileExists(atPath: cellarDir.path) ? cellarDir : nil,
                installedOnRequest: installedOnRequest,
                isPinned: pinned,
                isOutdated: outdated,
                isKegOnly: kegOnly,
                aliases: aliases,
                oldNames: oldNames,
                displayNames: [name],
                dependencies: dependencies,
                runtimeDependencies: runtimeDeps,
                requiredBy: reqBy,
                serviceName: serviceName,
                serviceRunning: svcStatus?.isRunning ?? false,
                servicePlistPath: svcStatus?.file
            ))
        }

        for c in rawCasks {
            guard let token = c["token"] as? String else { continue }
            let fullToken = c["full_token"] as? String ?? token
            let tap = c["tap"] as? String ?? "homebrew/cask"
            let desc = c["desc"] as? String
            let homepage = c["homepage"] as? String
            let oldTokens = c["old_tokens"] as? [String] ?? []
            let displayNames = c["name"] as? [String] ?? [token]
            let pinned = c["pinned"] as? Bool ?? false
            let outdated = c["outdated"] as? Bool ?? false
            let installedVersion = (c["installed"] as? String) ?? "unknown"

            var installedTime: Date?
            if let epoch = c["installed_time"] as? TimeInterval {
                installedTime = Date(timeIntervalSince1970: epoch)
            } else if let epochInt = c["installed_time"] as? Int {
                installedTime = Date(timeIntervalSince1970: TimeInterval(epochInt))
            }

            let caskroomDir = URL(fileURLWithPath: prefix).appendingPathComponent("Caskroom/\(token)").standardized
            let parsedArtifacts = parseCaskArtifacts(c["artifacts"] as? [[String: Any]] ?? [])

            var formulaDeps: [String] = []
            if let dependsOn = c["depends_on"] as? [String: Any],
               let formulas = dependsOn["formula"] as? [String] {
                formulaDeps = formulas
            }

            packages.append(HomebrewPackageInfo(
                name: token,
                fullName: fullToken,
                kind: .cask,
                tap: tap,
                version: installedVersion,
                installedTime: installedTime,
                descriptionText: desc,
                homepage: homepage,
                prefixPath: prefix,
                cellarOrCaskroomURL: fileManager.fileExists(atPath: caskroomDir.path) ? caskroomDir : nil,
                installedOnRequest: true,
                isPinned: pinned,
                isOutdated: outdated,
                isKegOnly: false,
                aliases: [],
                oldNames: oldTokens,
                displayNames: displayNames,
                dependencies: formulaDeps,
                runtimeDependencies: formulaDeps,
                requiredBy: [],
                artifactAppPaths: parsedArtifacts.apps,
                artifactBinaryPaths: parsedArtifacts.binaries,
                artifactFontPaths: parsedArtifacts.fonts,
                artifactManpagePaths: parsedArtifacts.manpages,
                artifactPkgIDs: parsedArtifacts.pkgIDs,
                zapTrashPaths: parsedArtifacts.zapTrash,
                zapDeletePaths: parsedArtifacts.zapDelete,
                zapRmdirPaths: parsedArtifacts.zapRmdir
            ))
        }

        return packages
    }

    public func stopService(_ name: String) throws {
        guard let brew = brewExecutablePath() else {
            throw SweepError.general("Homebrew (brew) executable not found.")
        }
        let res = runBrew(brew, ["services", "stop", name])
        if res.status != 0 {
            let err = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SweepError.executionFailed("Failed to stop Homebrew service '\(name)': \(err)")
        }
    }

    public func uninstall(package: HomebrewPackageInfo, ignoreDependencies: Bool, force: Bool) throws -> String {
        guard let brew = brewExecutablePath() else {
            throw SweepError.general("Homebrew (brew) executable not found.")
        }
        var args = ["uninstall"]
        args.append(package.kind == .cask ? "--cask" : "--formula")
        if ignoreDependencies && package.kind == .formula {
            args.append("--ignore-dependencies")
        }
        if force {
            args.append("--force")
        }
        args.append(package.fullName)

        let res = runBrew(brew, args)
        let combined = [res.stdout, res.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        if res.status != 0 {
            throw SweepError.executionFailed(combined.isEmpty ? "brew uninstall exited with code \(res.status)" : combined)
        }
        return combined
    }

    public func autoremove(dryRun: Bool) throws -> String {
        guard let brew = brewExecutablePath() else {
            throw SweepError.general("Homebrew (brew) executable not found.")
        }
        var args = ["autoremove"]
        if dryRun {
            args.append("--dry-run")
        }
        let res = runBrew(brew, args)
        let combined = [res.stdout, res.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if res.status != 0 {
            throw SweepError.executionFailed(combined.isEmpty ? "brew autoremove exited with code \(res.status)" : combined)
        }
        return combined
    }

    // MARK: - Helpers

    private struct ParsedCaskArtifacts {
        var apps: [String] = []
        var binaries: [String] = []
        var fonts: [String] = []
        var manpages: [String] = []
        var pkgIDs: [String] = []
        var zapTrash: [String] = []
        var zapDelete: [String] = []
        var zapRmdir: [String] = []
    }

    private func parseCaskArtifacts(_ artifacts: [[String: Any]]) -> ParsedCaskArtifacts {
        var parsed = ParsedCaskArtifacts()

        for artifact in artifacts {
            if let appEntries = artifact["app"] as? [Any] {
                if let target = artifact["target"] as? String {
                    parsed.apps.append(target)
                } else {
                    for entry in appEntries {
                        if let name = entry as? String {
                            parsed.apps.append("/Applications/\(name)")
                        } else if let dict = entry as? [String: Any], let target = dict["target"] as? String {
                            parsed.apps.append(target.hasPrefix("/") ? target : "/Applications/\(target)")
                        }
                    }
                }
            }

            if artifact["binary"] != nil, let target = artifact["target"] as? String {
                parsed.binaries.append(target)
            }
            if artifact["font"] != nil, let target = artifact["target"] as? String {
                parsed.fonts.append(target)
            }
            if artifact["manpage"] != nil, let target = artifact["target"] as? String {
                parsed.manpages.append(target)
            }

            if let uninstallItems = artifact["uninstall"] as? [[String: Any]] {
                for entry in uninstallItems {
                    appendStrings(from: entry["pkgutil"], into: &parsed.pkgIDs)
                }
            }

            if let zapItems = artifact["zap"] as? [[String: Any]] {
                for entry in zapItems {
                    appendStrings(from: entry["trash"], into: &parsed.zapTrash)
                    appendStrings(from: entry["delete"], into: &parsed.zapDelete)
                    appendStrings(from: entry["rmdir"], into: &parsed.zapRmdir)
                    appendStrings(from: entry["pkgutil"], into: &parsed.pkgIDs)
                }
            }
        }

        return parsed
    }

    private func appendStrings(from value: Any?, into dest: inout [String]) {
        if let single = value as? String {
            dest.append(single)
        } else if let array = value as? [Any] {
            for item in array {
                if let s = item as? String {
                    dest.append(s)
                }
            }
        }
    }

    private func runBrew(_ executable: String, _ arguments: [String]) -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_COLOR"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            var outData = Data()
            var errData = Data()
            let group = DispatchGroup()

            group.enter()
            DispatchQueue.global().async {
                outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }

            process.waitUntilExit()
            group.wait()

            return (
                process.terminationStatus,
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? ""
            )
        } catch {
            return (-1, "", error.localizedDescription)
        }
    }
}
