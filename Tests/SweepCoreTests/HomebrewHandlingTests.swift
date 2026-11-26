import XCTest
@testable import SweepCore

final class HomebrewHandlingTests: XCTestCase {
    private final class StubPrivilegeHandler: PrivilegeHandling {
        var isRoot: Bool = false
        func canWrite(to url: URL) -> Bool { true }
        func hasCachedSudo() -> Bool { true }
        func authenticateIfNeeded() throws {}
        func removeWithPrivilege(at url: URL) throws {
            try FileManager.default.removeItem(at: url)
        }
        func forgetPackageReceipt(_ packageID: String) throws {}
    }

    private final class StubHomebrewReader: HomebrewReading {
        var packages: [HomebrewPackageInfo] = []
        var prefix: String = "/opt/homebrew"
        var cacheDir: URL?
        var uninstalled: [String] = []

        func isAvailable() -> Bool { true }
        func brewExecutablePath() -> String? { "\(prefix)/bin/brew" }
        func brewPrefix() -> String { prefix }
        func cacheDirectory() -> URL? { cacheDir }
        func brewVersion() -> String? { "Homebrew 7.0.16" }
        func installedPackages() throws -> [HomebrewPackageInfo] { packages }
        func runningServices() -> [String: HomebrewServiceStatus] { [:] }
        func stopService(_ name: String) throws {}
        func uninstall(package: HomebrewPackageInfo, ignoreDependencies: Bool, force: Bool) throws -> String {
            uninstalled.append(package.fullName)
            return "Uninstalled"
        }
        func autoremove(dryRun: Bool) throws -> String { "" }
    }

    func testHomebrewScanAndRemoveWithLeftovers() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.cleanUp() }

        let fm = FileManager.default
        let prefix = sandbox.rootURL.appendingPathComponent("opt/homebrew")
        let cellar = prefix.appendingPathComponent("Cellar/demo/1.0")
        let etcDir = prefix.appendingPathComponent("etc/demo")
        try fm.createDirectory(at: cellar, withIntermediateDirectories: true)
        try fm.createDirectory(at: etcDir, withIntermediateDirectories: true)
        try "bin".write(to: cellar.appendingPathComponent("demo"), atomically: true, encoding: .utf8)
        try "cfg".write(to: etcDir.appendingPathComponent("demo.conf"), atomically: true, encoding: .utf8)

        let pkg = HomebrewPackageInfo(
            name: "demo",
            fullName: "demo",
            kind: .formula,
            version: "1.0",
            prefixPath: prefix.path,
            cellarOrCaskroomURL: cellar
        )

        let stub = StubHomebrewReader()
        stub.prefix = prefix.path
        stub.packages = [pkg]

        let guardInstance = SafetyGuard(customAllowedRoot: sandbox.rootURL)
        let scanner = HomebrewScanner(
            fileManager: fm,
            reader: stub,
            safetyGuard: guardInstance,
            privilegeHandler: StubPrivilegeHandler(),
            customHomeDirectory: sandbox.userHomeURL
        )
        let scan = try scanner.scan(packageInfo: pkg)
        XCTAssertTrue(scan.cleanupItems.contains { $0.url.standardized.path == etcDir.standardized.path })

        let remover = HomebrewRemover(
            fileManager: fm,
            reader: stub,
            safetyGuard: guardInstance,
            historyLogger: HistoryLogger(fileManager: fm, customManifestURL: sandbox.rootURL.appendingPathComponent("history.json")),
            privilegeHandler: StubPrivilegeHandler()
        )
        let plan = HomebrewRemovalPlan(packageInfo: pkg, selectedCleanupItems: scan.cleanupItems, isPermanent: true)
        let res = try remover.execute(plan: plan)
        XCTAssertTrue(res.isCompleteSuccess)
        XCTAssertEqual(stub.uninstalled, ["demo"])
        XCTAssertFalse(fm.fileExists(atPath: etcDir.path))
    }
}
