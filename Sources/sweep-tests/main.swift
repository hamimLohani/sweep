import Foundation
import SweepCore

// ANSI test output helpers
func pass(_ name: String) {
    print("\u{001B}[32m  ✔ [PASS]\u{001B}[0m \(name)")
}

func fail(_ name: String, _ reason: String) {
    print("\u{001B}[1;31m  ✖ [FAIL]\u{001B}[0m \(name): \(reason)")
    exit(1)
}

func assert(_ condition: Bool, _ name: String, _ reason: String = "Condition was false") {
    if condition {
        pass(name)
    } else {
        fail(name, reason)
    }
}

func assertThrows<T>(_ expression: () throws -> T, _ name: String) {
    do {
        _ = try expression()
        fail(name, "Expected error to be thrown, but succeeded")
    } catch {
        pass(name)
    }
}

// Sandbox Helper
final class TestSandbox {
    let rootURL: URL
    let applicationsURL: URL
    let userHomeURL: URL
    let userLibraryURL: URL
    let fileManager = FileManager.default

    init() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sweep_test_\(UUID().uuidString)")
        self.rootURL = tempDir
        self.applicationsURL = tempDir.appendingPathComponent("Applications")
        self.userHomeURL = tempDir.appendingPathComponent("UserHome")
        self.userLibraryURL = userHomeURL.appendingPathComponent("Library")

        try fileManager.createDirectory(at: applicationsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: userLibraryURL.appendingPathComponent("Application Support"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: userLibraryURL.appendingPathComponent("Caches"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: userLibraryURL.appendingPathComponent("Preferences"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: userLibraryURL.appendingPathComponent("Containers"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: userLibraryURL.appendingPathComponent("Saved Application State"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: userLibraryURL.appendingPathComponent("LaunchAgents"), withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? fileManager.removeItem(at: rootURL)
    }

    func createDummyApp(bundleName: String, bundleIdentifier: String, executableName: String = "AppBinary", version: String = "1.0.0") throws -> URL {
        let appBundleURL = applicationsURL.appendingPathComponent("\(bundleName).app")
        let contentsURL = appBundleURL.appendingPathComponent("Contents")
        let macosURL = contentsURL.appendingPathComponent("MacOS")

        try fileManager.createDirectory(at: macosURL, withIntermediateDirectories: true)
        let execURL = macosURL.appendingPathComponent(executableName)
        try "dummy-binary".write(to: execURL, atomically: true, encoding: .utf8)

        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": bundleName,
            "CFBundleDisplayName": bundleName,
            "CFBundleExecutable": executableName,
            "CFBundleShortVersionString": version
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return appBundleURL
    }

    func populateLeftovers(bundleIdentifier: String, bundleName: String, vendorToken: String?) throws {
        let container = userLibraryURL.appendingPathComponent("Containers").appendingPathComponent(bundleIdentifier)
        try fileManager.createDirectory(at: container, withIntermediateDirectories: true)
        try "container-content".write(to: container.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)

        let pref = userLibraryURL.appendingPathComponent("Preferences").appendingPathComponent("\(bundleIdentifier).plist")
        try "pref-content".write(to: pref, atomically: true, encoding: .utf8)

        let appSupport = userLibraryURL.appendingPathComponent("Application Support").appendingPathComponent(bundleName)
        try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try "app-support-data".write(to: appSupport.appendingPathComponent("db.sqlite"), atomically: true, encoding: .utf8)

        let cache = userLibraryURL.appendingPathComponent("Caches").appendingPathComponent(bundleName)
        try fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
        try "cache-data".write(to: cache.appendingPathComponent("cache.bin"), atomically: true, encoding: .utf8)

        if let vendor = vendorToken {
            let vendorFolder = userLibraryURL.appendingPathComponent("Application Support").appendingPathComponent(vendor)
            try fileManager.createDirectory(at: vendorFolder, withIntermediateDirectories: true)
            try "vendor-data".write(to: vendorFolder.appendingPathComponent("vendor.txt"), atomically: true, encoding: .utf8)
        }

        // Noise
        let noiseAppSupport = userLibraryURL.appendingPathComponent("Application Support").appendingPathComponent("UnrelatedSoftware")
        try fileManager.createDirectory(at: noiseAppSupport, withIntermediateDirectories: true)
        try "noise".write(to: noiseAppSupport.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let noisePref = userLibraryURL.appendingPathComponent("Preferences").appendingPathComponent("com.unrelated.tool.plist")
        try "noise".write(to: noisePref, atomically: true, encoding: .utf8)
    }
}

// ----------------- TEST SUITE EXECUTION -----------------
print("\u{001B}[1mRunning SweepCore Unit Test Suite...\u{001B}[0m\n")

// Suite 1: AppResolverTests
print("\u{001B}[1;34m▶ Suite: AppResolverTests\u{001B}[0m")
do {
    let sandbox = try TestSandbox()
    defer { sandbox.cleanUp() }

    _ = try sandbox.createDummyApp(bundleName: "TestChat", bundleIdentifier: "com.example.testchat")
    let resolver = AppResolver(customSearchDirectories: [sandbox.applicationsURL])

    // Test 1: Resolve by bundle ID
    let appByBundle = try resolver.resolve(target: "com.example.testchat")
    assert(appByBundle.bundleName == "TestChat", "Resolve by bundle ID matches app name")
    assert(appByBundle.vendorToken == "example", "Resolve extracts correct vendor token")

    // Test 2: Resolve by app name
    let appByName = try resolver.resolve(target: "TestChat")
    assert(appByName.bundleIdentifier == "com.example.testchat", "Resolve by name matches bundle ID")

    // Test 3: Resolve by direct path
    let directAppURL = try sandbox.createDummyApp(bundleName: "DirectApp", bundleIdentifier: "com.direct.app")
    let appByPath = try resolver.resolve(target: directAppURL.path)
    assert(appByPath.bundleName == "DirectApp", "Resolve by path succeeds")

    // Test 3b: Resolve with trailing slash (tab-completion support)
    let appByTrailingSlash = try resolver.resolve(target: directAppURL.path + "/")
    assert(appByTrailingSlash.bundleName == "DirectApp", "Resolve by path with trailing slash succeeds")
    let appByNameWithExtSlash = try resolver.resolve(target: "DirectApp.app/")
    assert(appByNameWithExtSlash.bundleName == "DirectApp", "Resolve by name with .app/ succeeds")

    // Test 4: Vendor token extraction edge cases
    assert(resolver.extractVendorToken(from: "com.tinyspeck.slackmacgap") == "tinyspeck", "Vendor token: tinyspeck")
    assert(resolver.extractVendorToken(from: "org.mozilla.firefox") == "mozilla", "Vendor token: mozilla")
    assert(resolver.extractVendorToken(from: "io.github.someone.tool") == "someone", "Vendor token skips generic 'github' prefix")
    assert(resolver.extractVendorToken(from: "com.x") == nil, "Vendor token: too short returns nil")

    // Test 5: Non-existent app throws appNotFound
    assertThrows({ try resolver.resolve(target: "NonExistentAppXYZ") }, "Non-existent app throws error")
} catch {
    fail("AppResolverTests", "\(error)")
}

// Suite 2: LeftoverScannerTests
print("\n\u{001B}[1;34m▶ Suite: LeftoverScannerTests\u{001B}[0m")
do {
    let sandbox = try TestSandbox()
    defer { sandbox.cleanUp() }

    let bundleID = "com.samplecorp.musicplayer"
    let appName = "MusicPlayer"
    let vendor = "samplecorp"

    let appURL = try sandbox.createDummyApp(bundleName: appName, bundleIdentifier: bundleID)
    try sandbox.populateLeftovers(bundleIdentifier: bundleID, bundleName: appName, vendorToken: vendor)

    let appInfo = AppInfo(
        bundleURL: appURL,
        bundleIdentifier: bundleID,
        bundleName: appName,
        displayName: appName,
        executableName: "AppBinary",
        vendorToken: vendor,
        version: "1.0",
        bundleSizeBytes: 1024,
        isSystemApp: false
    )

    let scanner = LeftoverScanner(customHomeDirectory: sandbox.userHomeURL)
    let result = try scanner.scan(appInfo: appInfo)

    assert(!result.leftovers.isEmpty, "Scan found leftover files")

    let highMatches = result.leftovers.filter { $0.confidence == .high }
    assert(highMatches.contains { $0.url.lastPathComponent == "\(bundleID).plist" }, "High confidence: preference plist detected")
    assert(highMatches.contains { $0.url.lastPathComponent == bundleID }, "High confidence: container detected")

    let medMatches = result.leftovers.filter { $0.confidence == .medium }
    assert(medMatches.contains { $0.url.lastPathComponent == appName }, "Medium confidence: Application Support folder detected")

    let lowMatches = result.leftovers.filter { $0.confidence == .low }
    assert(lowMatches.contains { $0.url.lastPathComponent == vendor }, "Low confidence: vendor folder detected")

    // False positive checks: noise files must NOT be detected
    assert(!result.leftovers.contains { $0.url.lastPathComponent.contains("UnrelatedSoftware") }, "Noise application support folder ignored")
    assert(!result.leftovers.contains { $0.url.lastPathComponent.contains("com.unrelated.tool.plist") }, "Noise preference plist ignored")

    // Short app name check
    let shortApp = AppInfo(
        bundleURL: URL(fileURLWithPath: "/tmp/Go.app"),
        bundleIdentifier: "org.golang.go",
        bundleName: "Go",
        displayName: "Go",
        executableName: "go",
        vendorToken: nil,
        version: "1.0",
        bundleSizeBytes: 100,
        isSystemApp: false
    )
    let shortMatch = ConfidenceScorer.score(itemName: "Go", appInfo: shortApp, strategy: "bundleIdOrName")
    assert(shortMatch == nil, "Short 2-letter app names do not match arbitrary folders")
} catch {
    fail("LeftoverScannerTests", "\(error)")
}

// Suite 3: SafetyGuardTests
print("\n\u{001B}[1;34m▶ Suite: SafetyGuardTests\u{001B}[0m")
do {
    let sandbox = try TestSandbox()
    defer { sandbox.cleanUp() }

    let guardInstance = SafetyGuard(customAllowedRoot: sandbox.rootURL)

    // Test 1: System path rejection
    let systemPaths = ["/System", "/usr/bin", "/bin/sh", "/private/etc/hosts", "/Library/Keychains"]
    for path in systemPaths {
        let url = URL(fileURLWithPath: path)
        assertThrows({ try guardInstance.validate(itemURL: url) }, "SafetyGuard rejects \(path)")
    }

    // Test 2: Structural root directory rejection
    let rootFolder = sandbox.userHomeURL.appendingPathComponent("Library/Application Support")
    assertThrows({ try guardInstance.validate(itemURL: rootFolder) }, "SafetyGuard rejects structural root folder 'Application Support'")
    assertThrows({ try guardInstance.validate(itemURL: sandbox.userLibraryURL) }, "SafetyGuard rejects structural root folder 'Library'")
    assertThrows({ try guardInstance.validate(itemURL: sandbox.applicationsURL) }, "SafetyGuard rejects structural root folder 'Applications'")

    // Test 3: Symlink escape rejection
    let insideURL = sandbox.userLibraryURL.appendingPathComponent("Caches/malicious_symlink")
    try FileManager.default.createSymbolicLink(at: insideURL, withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
    assertThrows({ try guardInstance.validate(itemURL: insideURL) }, "SafetyGuard rejects symlink escaping to /etc/passwd")

    // Test 4: Safe sandbox item passes
    let safeFile = sandbox.userLibraryURL.appendingPathComponent("Preferences/com.safe.test.plist")
    try "safe".write(to: safeFile, atomically: true, encoding: .utf8)
    do {
        try guardInstance.validate(itemURL: safeFile)
        pass("SafetyGuard accepts valid sandbox item")
    } catch {
        fail("SafetyGuard safe item", "\(error)")
    }
} catch {
    fail("SafetyGuardTests", "\(error)")
}

// Suite 4: CacheScannerTests
print("\n\u{001B}[1;34m▶ Suite: CacheScannerTests\u{001B}[0m")
do {
    let sandbox = try TestSandbox()
    defer { sandbox.cleanUp() }

    let bundleID = "com.apple.Safari"
    let appName = "Safari"

    // Populate fake cache directory and fake preferences
    let fakeCache = sandbox.userLibraryURL.appendingPathComponent("Caches/\(bundleID)")
    try FileManager.default.createDirectory(at: fakeCache, withIntermediateDirectories: true)
    try "fake-cached-data".write(to: fakeCache.appendingPathComponent("cached.blob"), atomically: true, encoding: .utf8)

    let fakePref = sandbox.userLibraryURL.appendingPathComponent("Preferences/\(bundleID).plist")
    try "fake-pref".write(to: fakePref, atomically: true, encoding: .utf8)

    let safariApp = AppInfo(
        bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"),
        bundleIdentifier: bundleID,
        bundleName: appName,
        displayName: appName,
        executableName: "Safari",
        vendorToken: nil,
        version: "18.0",
        bundleSizeBytes: 50000000,
        isSystemApp: true
    )

    let guardInstance = SafetyGuard(customAllowedRoot: sandbox.rootURL)
    let cacheScanner = CacheScanner(fileManager: .default, safetyGuard: guardInstance, customHomeDirectory: sandbox.userHomeURL)

    let cacheResult = cacheScanner.scanCache(for: safariApp)
    assert(!cacheResult.cacheItems.isEmpty, "CacheScanner finds Safari cache folder")
    assert(cacheResult.cacheItems.contains { $0.url.lastPathComponent == bundleID }, "Cache folder matches bundle ID")
    assert(!cacheResult.cacheItems.contains { $0.url.lastPathComponent == "\(bundleID).plist" }, "CacheScanner never includes preferences")

    // Safety validation: App bundle deletion must be blocked even in cache mode
    assertThrows({
        try guardInstance.validate(itemURL: safariApp.bundleURL, for: safariApp, isCacheOnly: true)
    }, "SafetyGuard rejects deleting sealed system application bundle even in cache mode")
} catch {
    fail("CacheScannerTests", "\(error)")
}

// MARK: - Package Handling Test Doubles
final class StubPrivilegeHandler: PrivilegeHandling {
    var isRoot: Bool = false
    var writableOverride: Bool = true
    var forgottenPackages: [String] = []
    var shouldFailForget: Bool = false

    func canWrite(to url: URL) -> Bool {
        return writableOverride
    }
    func hasCachedSudo() -> Bool { true }
    func authenticateIfNeeded() throws {}
    func removeWithPrivilege(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
    func forgetPackageReceipt(_ packageID: String) throws {
        if shouldFailForget {
            throw SweepError.executionFailed("Simulated pkgutil --forget failure")
        }
        forgottenPackages.append(packageID)
    }
}

final class StubReceiptReader: ReceiptReading {
    var packages: [String: PackageInfo] = [:]
    var contentsMap: [String: PackageContents] = [:]
    var forgotten: [String] = []
    var failForget: Bool = false

    func allPackages() -> [String] {
        return Array(packages.keys).sorted()
    }

    func packageInfo(for pkgID: String, includeGroups: Bool) -> PackageInfo? {
        return packages[pkgID]
    }

    func packageContents(for pkgID: String) -> PackageContents {
        return contentsMap[pkgID] ?? PackageContents(files: [], directories: [])
    }

    func inspectOwnership(for pkgID: String, candidateFiles: [URL], candidateDirectories: [URL]) -> PackageOwnershipReport {
        let candidateFileSet = Set(candidateFiles.map { $0.standardized.path })
        let candidateDirSet = Set(candidateDirectories.map { $0.standardized.path })

        var sharedFiles: [String: [String]] = [:]
        var dirsWithOtherOwners = Set<String>()

        for (otherID, contents) in contentsMap where otherID != pkgID {
            for otherFile in contents.files {
                let path = otherFile.standardized.path
                if candidateFileSet.contains(path) {
                    sharedFiles[path, default: []].append(otherID)
                }
                for dirPath in candidateDirSet {
                    if path.hasPrefix(dirPath + "/") {
                        dirsWithOtherOwners.insert(dirPath)
                    }
                }
            }
        }

        return PackageOwnershipReport(
            sharedFiles: sharedFiles.mapValues { $0.sorted() },
            directoriesWithOtherOwners: dirsWithOtherOwners
        )
    }

    func forgetPackage(_ pkgID: String) throws {
        if failForget {
            throw SweepError.executionFailed("Simulated forget error")
        }
        forgotten.append(pkgID)
        packages.removeValue(forKey: pkgID)
        contentsMap.removeValue(forKey: pkgID)
    }

    func findPackages(matching bundleID: String, appName: String) -> [String] {
        return allPackages().filter { $0.lowercased().contains(bundleID.lowercased()) }
    }

    func filesForPackage(_ pkgID: String) -> [URL] {
        return packageContents(for: pkgID).files
    }
}

// Suite 5: PackageSafetyGuardTests
print("\n\u{001B}[1;34m▶ Suite: PackageSafetyGuardTests\u{001B}[0m")
do {
    let realGuard = SafetyGuard()

    let blockedPackagePaths = [
        "/usr",
        "/usr/bin",
        "/usr/bin/swift",
        "/usr/lib/libSystem.B.dylib",
        "/usr/local",
        "/usr/local/bin",
        "/usr/local/lib",
        "/usr/local/share/man",
        "/usr/local/share/man/man1",
        "/opt",
        "/opt/homebrew",
        "/opt/local",
        "/Library/Fonts",
        "/Library/Input Methods",
        "/Library/Java/JavaVirtualMachines",
        "/Library/Receipts"
    ]
    for path in blockedPackagePaths {
        assertThrows({ try realGuard.validate(itemURL: URL(fileURLWithPath: path)) }, "SafetyGuard rejects protected package path \(path)")
    }

    let allowedPackagePaths = [
        "/usr/local/bin/ghostscript",
        "/usr/local/mysql-9.3.0-macos15-arm64/bin/mysql",
        "/usr/local/share/ghostscript/10.07.0",
        "/opt/mytool/bin/cli",
        "/Library/Java/JavaVirtualMachines/temurin-17.jdk",
        "/Library/Fonts/CustomFont.ttf",
        "/Library/LaunchDaemons/org.example.daemon.plist"
    ]
    for path in allowedPackagePaths {
        do {
            try realGuard.validate(itemURL: URL(fileURLWithPath: path))
            pass("SafetyGuard accepts valid package path \(path)")
        } catch {
            fail("SafetyGuard valid package path \(path)", "\(error)")
        }
    }

    // Cache mode must still disallow /usr/local and /opt
    assertThrows({
        try realGuard.validate(itemURL: URL(fileURLWithPath: "/usr/local/bin/ghostscript"), isCacheOnly: true)
    }, "SafetyGuard blocks /usr/local in cache-only mode")
    assertThrows({
        try realGuard.validate(itemURL: URL(fileURLWithPath: "/opt/mytool/cache"), isCacheOnly: true)
    }, "SafetyGuard blocks /opt in cache-only mode")

    assert(SafetyGuard.isProtectedSystemPackage(packageID: "com.apple.files.data-template"), "System package com.apple.files.data-template is protected")
    assert(SafetyGuard.isProtectedSystemPackage(packageID: "com.apple.pkg.XProtectPayloads_10_15.16U4464"), "System package XProtect is protected")
    assert(!SafetyGuard.isProtectedSystemPackage(packageID: "org.wireshark.ChmodBPF.pkg"), "Third-party package ChmodBPF is not protected")
}

// Suite 6: PackageResolverTests
print("\n\u{001B}[1;34m▶ Suite: PackageResolverTests\u{001B}[0m")
do {
    let stub = StubReceiptReader()
    stub.packages = [
        "com.apple.files.data-template": PackageInfo(packageIdentifier: "com.apple.files.data-template", version: "27.2.1"),
        "org.wireshark.ChmodBPF.pkg": PackageInfo(packageIdentifier: "org.wireshark.ChmodBPF.pkg", version: "1.2", packageFileName: "ChmodBPF.pkg"),
        "org.tug.mactex.ghostscript10.03.0": PackageInfo(packageIdentifier: "org.tug.mactex.ghostscript10.03.0", version: "10.03.0", packageFileName: "Ghostscript-10.03.0.pkg"),
        "org.tug.mactex.ghostscript10.07.0": PackageInfo(packageIdentifier: "org.tug.mactex.ghostscript10.07.0", version: "10.07.0", packageFileName: "Ghostscript-10.07.0.pkg"),
        "net.temurin.17.jdk": PackageInfo(packageIdentifier: "net.temurin.17.jdk", version: "17.0.14+7", installLocation: "Library/Java/JavaVirtualMachines/temurin-17.jdk")
    ]

    let resolver = PackageResolver(receiptReader: stub)
    let thirdParty = resolver.listInstalledPackages(includeApple: false)
    assert(thirdParty.count == 4, "listInstalledPackages excludes Apple packages by default")

    let allPkgs = resolver.listInstalledPackages(includeApple: true)
    assert(allPkgs.count == 5, "listInstalledPackages --all includes Apple packages")

    let filtered = resolver.listInstalledPackages(includeApple: false, filter: "temurin")
    assert(filtered.count == 1 && filtered[0].packageIdentifier == "net.temurin.17.jdk", "listInstalledPackages filter matches package")

    let exact = try resolver.resolve(target: "ORG.WIRESHARK.CHMODBPF.PKG")
    assert(exact.packageIdentifier == "org.wireshark.ChmodBPF.pkg", "Resolve exact package ID case-insensitively")

    let bySegment = try resolver.resolve(target: "ChmodBPF")
    assert(bySegment.packageIdentifier == "org.wireshark.ChmodBPF.pkg", "Resolve by trailing segment")

    let byFilename = try resolver.resolve(target: "Ghostscript-10.03.0.pkg")
    assert(byFilename.packageIdentifier == "org.tug.mactex.ghostscript10.03.0", "Resolve by installer filename")

    let bySubstring = try resolver.resolve(target: "temurin")
    assert(bySubstring.packageIdentifier == "net.temurin.17.jdk", "Resolve by unique substring")

    assertThrows({ try resolver.resolve(target: "ghostscript") }, "Ambiguous package query throws error")
    assertThrows({ try resolver.resolve(target: "nonexistent.pkg") }, "Unknown package query throws packageNotFound")
} catch {
    fail("PackageResolverTests", "\(error)")
}

// Suite 7: PackageScannerTests
print("\n\u{001B}[1;34m▶ Suite: PackageScannerTests\u{001B}[0m")
do {
    let sandbox = try TestSandbox()
    defer { sandbox.cleanUp() }

    let fm = FileManager.default
    let usrLocalBin = sandbox.rootURL.appendingPathComponent("usr/local/bin")
    let docDir = sandbox.rootURL.appendingPathComponent("usr/local/share/tool/1.0")
    let dataToolDir = sandbox.rootURL.appendingPathComponent("usr/local/mytool")
    let jdkBundle = sandbox.rootURL.appendingPathComponent("Library/Java/JavaVirtualMachines/demo-17.jdk")

    try fm.createDirectory(at: usrLocalBin, withIntermediateDirectories: true)
    try fm.createDirectory(at: docDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: dataToolDir.appendingPathComponent("bin"), withIntermediateDirectories: true)
    try fm.createDirectory(at: dataToolDir.appendingPathComponent("data"), withIntermediateDirectories: true)
    try fm.createDirectory(at: jdkBundle.appendingPathComponent("Contents/Home/bin"), withIntermediateDirectories: true)

    let sharedBin = usrLocalBin.appendingPathComponent("shared-cli")
    let exclusiveBin = usrLocalBin.appendingPathComponent("exclusive-cli")
    let docFile = docDir.appendingPathComponent("README.txt")
    let toolExec = dataToolDir.appendingPathComponent("bin/mytool")
    let runtimeUserData = dataToolDir.appendingPathComponent("data/prod.db")
    let jdkExec = jdkBundle.appendingPathComponent("Contents/Home/bin/java")
    let missingFile = usrLocalBin.appendingPathComponent("already-deleted")
    let runtimePref = sandbox.userLibraryURL.appendingPathComponent("Preferences/com.example.pkgtool.plist")

    try "shared".write(to: sharedBin, atomically: true, encoding: .utf8)
    try "exclusive".write(to: exclusiveBin, atomically: true, encoding: .utf8)
    try "doc".write(to: docFile, atomically: true, encoding: .utf8)
    try "exec".write(to: toolExec, atomically: true, encoding: .utf8)
    try "IMPORTANT-USER-DB".write(to: runtimeUserData, atomically: true, encoding: .utf8)
    try "java".write(to: jdkExec, atomically: true, encoding: .utf8)
    try "pref".write(to: runtimePref, atomically: true, encoding: .utf8)

    let pkgA = PackageInfo(packageIdentifier: "com.example.pkgtool", version: "1.0.0", installLocation: "/")
    let pkgB = PackageInfo(packageIdentifier: "com.other.sibling", version: "2.0.0", installLocation: "/")

    let stub = StubReceiptReader()
    stub.packages = [
        pkgA.packageIdentifier: pkgA,
        pkgB.packageIdentifier: pkgB
    ]
    stub.contentsMap[pkgA.packageIdentifier] = PackageContents(
        files: [sharedBin, exclusiveBin, docFile, toolExec, jdkExec, missingFile, URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")],
        directories: [usrLocalBin, docDir, dataToolDir, dataToolDir.appendingPathComponent("bin"), jdkBundle]
    )
    stub.contentsMap[pkgB.packageIdentifier] = PackageContents(
        files: [sharedBin],
        directories: [usrLocalBin]
    )

    let guardInstance = SafetyGuard(customAllowedRoot: sandbox.rootURL)
    let scanner = PackageScanner(
        fileManager: fm,
        receiptReader: stub,
        safetyGuard: guardInstance,
        privilegeHandler: StubPrivilegeHandler(),
        customHomeDirectory: sandbox.userHomeURL
    )

    let scanResult = try scanner.scan(packageInfo: pkgA)

    // Shared file must NOT be in removable items, and MUST be in sharedFiles
    assert(!scanResult.items.contains { $0.url.standardized.path == sharedBin.standardized.path }, "Shared file excluded from removal candidates")
    assert(scanResult.sharedFiles.contains { $0.url.standardized.path == sharedBin.standardized.path && $0.sharedWithPackages == [pkgB.packageIdentifier] }, "Shared file recorded with owning sibling package")

    // Missing & protected files tracked accurately
    assert(scanResult.missingFilePaths.contains { $0.standardized.path == missingFile.standardized.path }, "Missing file tracked in missingFilePaths")
    assert(scanResult.protectedSkippedPaths.contains { $0.path == "/System/Library/CoreServices/Finder.app" }, "System path excluded in protectedSkippedPaths")

    // Bundle collapse: .jdk and clean docDir collapsed; mytool (which has runtimeUserData!) NOT collapsed
    assert(scanResult.items.contains { $0.url.standardized.path == jdkBundle.standardized.path }, "Exclusive .jdk bundle collapsed into single item")
    assert(scanResult.items.contains { $0.url.standardized.path == docDir.standardized.path }, "Receipt-only directory collapsed into single item")
    assert(!scanResult.items.contains { $0.url.standardized.path == dataToolDir.standardized.path }, "Directory with untracked runtime user data is NOT collapsed")
    assert(scanResult.items.contains { $0.url.standardized.path == dataToolDir.appendingPathComponent("bin").standardized.path }, "Purely receipt-owned subdirectory 'bin' IS collapsed while preserving sibling 'data/'")
    assert(scanResult.items.contains { $0.url.standardized.path == exclusiveBin.standardized.path }, "Exclusive binary in shared bin directory is listed")
    assert(scanResult.items.contains { $0.url.resolvingSymlinksInPath().standardized.path == runtimePref.resolvingSymlinksInPath().standardized.path }, "Associated runtime preference leftover detected")

    // Expand mode should list individual files instead of collapsing
    let expanded = try scanner.scan(packageInfo: pkgA, expandCollapsedDirectories: true)
    assert(expanded.items.contains { $0.url.standardized.path == jdkExec.standardized.path }, "Expanded scan lists individual file inside .jdk bundle")
    assert(expanded.items.contains { $0.url.standardized.path == docFile.standardized.path }, "Expanded scan lists individual file inside docDir")
    assert(expanded.items.contains { $0.url.standardized.path == toolExec.standardized.path }, "Expanded scan lists tracked binary inside subdirectory")
} catch {
    fail("PackageScannerTests", "\(error)")
}

// Suite 8: PackageRemoverTests
print("\n\u{001B}[1;34m▶ Suite: PackageRemoverTests\u{001B}[0m")
do {
    let sandbox = try TestSandbox()
    defer { sandbox.cleanUp() }

    let fm = FileManager.default
    let usrLocalBin = sandbox.rootURL.appendingPathComponent("usr/local/bin")
    let dataToolDir = sandbox.rootURL.appendingPathComponent("usr/local/mytool")
    let historyURL = sandbox.rootURL.appendingPathComponent("history.json")
    try fm.createDirectory(at: usrLocalBin, withIntermediateDirectories: true)
    try fm.createDirectory(at: dataToolDir.appendingPathComponent("bin"), withIntermediateDirectories: true)
    try fm.createDirectory(at: dataToolDir.appendingPathComponent("data"), withIntermediateDirectories: true)

    let sharedBin = usrLocalBin.appendingPathComponent("shared-cli")
    let exclusiveBin = usrLocalBin.appendingPathComponent("exclusive-cli")
    let toolExec = dataToolDir.appendingPathComponent("bin/mytool")
    let runtimeUserData = dataToolDir.appendingPathComponent("data/prod.db")

    try "shared".write(to: sharedBin, atomically: true, encoding: .utf8)
    try "exclusive".write(to: exclusiveBin, atomically: true, encoding: .utf8)
    try "exec".write(to: toolExec, atomically: true, encoding: .utf8)
    try "IMPORTANT-USER-DB".write(to: runtimeUserData, atomically: true, encoding: .utf8)

    let pkgA = PackageInfo(packageIdentifier: "com.example.pkgtool", version: "1.0.0", installLocation: "/")
    let pkgB = PackageInfo(packageIdentifier: "com.other.sibling", version: "2.0.0", installLocation: "/")

    let stub = StubReceiptReader()
    stub.packages = [pkgA.packageIdentifier: pkgA, pkgB.packageIdentifier: pkgB]
    stub.contentsMap[pkgA.packageIdentifier] = PackageContents(
        files: [sharedBin, exclusiveBin, toolExec],
        directories: [usrLocalBin, dataToolDir, dataToolDir.appendingPathComponent("bin")]
    )
    stub.contentsMap[pkgB.packageIdentifier] = PackageContents(
        files: [sharedBin],
        directories: [usrLocalBin]
    )

    let guardInstance = SafetyGuard(customAllowedRoot: sandbox.rootURL)
    let privStub = StubPrivilegeHandler()
    let historyLogger = HistoryLogger(fileManager: fm, customManifestURL: historyURL)
    let scanner = PackageScanner(
        fileManager: fm,
        receiptReader: stub,
        safetyGuard: guardInstance,
        privilegeHandler: privStub,
        customHomeDirectory: sandbox.userHomeURL
    )
    let remover = TrashRemover(
        fileManager: fm,
        safetyGuard: guardInstance,
        historyLogger: historyLogger,
        privilegeHandler: privStub
    )

    let scanResult = try scanner.scan(packageInfo: pkgA)

    // 1. Dry-run must leave everything intact
    let dryPlan = PackageRemovalPlan(
        packageInfo: pkgA,
        selectedItems: scanResult.items,
        candidateEmptyDirectories: scanResult.candidateEmptyDirectories,
        isPermanent: true,
        dryRun: true
    )
    let dryRes = try remover.executePackageRemoval(plan: dryPlan, receiptManager: stub)
    assert(dryRes.isCompleteSuccess && !dryRes.receiptForgotten, "Dry-run package removal succeeds without forgetting receipt")
    assert(fm.fileExists(atPath: exclusiveBin.path) && fm.fileExists(atPath: toolExec.path), "Dry-run leaves all files untouched")
    assert(!fm.fileExists(atPath: historyURL.path), "Dry-run does not write history manifest")

    // 2. Real removal (keepReceipt = false)
    let realPlan = PackageRemovalPlan(
        packageInfo: pkgA,
        selectedItems: scanResult.items,
        candidateEmptyDirectories: scanResult.candidateEmptyDirectories,
        isPermanent: true,
        dryRun: false,
        keepReceipt: false
    )
    let execRes = try remover.executePackageRemoval(plan: realPlan, receiptManager: stub)
    assert(execRes.isCompleteSuccess, "Package removal completes cleanly")
    assert(!fm.fileExists(atPath: exclusiveBin.path) && !fm.fileExists(atPath: toolExec.path), "Package binaries removed")
    assert(fm.fileExists(atPath: sharedBin.path), "Shared sibling file preserved on disk")
    assert(fm.fileExists(atPath: runtimeUserData.path), "Untracked runtime user database preserved on disk")
    assert(!fm.fileExists(atPath: dataToolDir.appendingPathComponent("bin").path), "Empty package subdirectory pruned after file removal")
    assert(fm.fileExists(atPath: usrLocalBin.path), "Protected structural root usr/local/bin preserved")
    assert(execRes.receiptForgotten && stub.forgotten.contains(pkgA.packageIdentifier), "Package receipt forgotten via pkgutil --forget")

    let history = historyLogger.loadHistory()
    assert(history.count == 1 && history[0].forgottenPackageID == pkgA.packageIdentifier, "Removal audit record logs forgottenPackageID")

    // 3. Protected system package must throw inside TrashRemover
    let sysPkg = PackageInfo(packageIdentifier: "com.apple.files.data-template", version: "1.0")
    let sysPlan = PackageRemovalPlan(packageInfo: sysPkg, selectedItems: [])
    assertThrows({ try remover.executePackageRemoval(plan: sysPlan, receiptManager: stub) }, "TrashRemover rejects protected system package")
} catch {
    fail("PackageRemoverTests", "\(error)")
}

print("\n\u{001B}[1;32m🎉 All Unit Tests Passed Successfully!\u{001B}[0m\n")

