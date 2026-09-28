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

    // Test 4: Vendor token extraction edge cases
    assert(resolver.extractVendorToken(from: "com.tinyspeck.slackmacgap") == "tinyspeck", "Vendor token: tinyspeck")
    assert(resolver.extractVendorToken(from: "org.mozilla.firefox") == "mozilla", "Vendor token: mozilla")
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

print("\n\u{001B}[1;32m🎉 All Unit Tests Passed Successfully!\u{001B}[0m\n")
