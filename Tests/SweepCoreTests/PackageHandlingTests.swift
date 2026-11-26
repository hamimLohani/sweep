import XCTest
@testable import SweepCore

final class PackageHandlingTests: XCTestCase {
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

    private final class StubReceiptReader: ReceiptReading {
        var packages: [String: PackageInfo] = [:]
        var contentsMap: [String: PackageContents] = [:]
        var forgotten: [String] = []

        func allPackages() -> [String] { Array(packages.keys).sorted() }
        func packageInfo(for pkgID: String, includeGroups: Bool) -> PackageInfo? { packages[pkgID] }
        func packageContents(for pkgID: String) -> PackageContents {
            contentsMap[pkgID] ?? PackageContents(files: [], directories: [])
        }
        func inspectOwnership(for pkgID: String, candidateFiles: [URL], candidateDirectories: [URL]) -> PackageOwnershipReport {
            let fileSet = Set(candidateFiles.map { $0.standardized.path })
            var shared: [String: [String]] = [:]
            for (otherID, contents) in contentsMap where otherID != pkgID {
                for file in contents.files where fileSet.contains(file.standardized.path) {
                    shared[file.standardized.path, default: []].append(otherID)
                }
            }
            return PackageOwnershipReport(sharedFiles: shared.mapValues { $0.sorted() })
        }
        func forgetPackage(_ pkgID: String) throws {
            forgotten.append(pkgID)
            packages.removeValue(forKey: pkgID)
        }
        func findPackages(matching bundleID: String, appName: String) -> [String] { [] }
        func filesForPackage(_ pkgID: String) -> [URL] { packageContents(for: pkgID).files }
    }

    func testPackageResolverAndSharedRemoval() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.cleanUp() }

        let fm = FileManager.default
        let binDir = sandbox.rootURL.appendingPathComponent("usr/local/bin")
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)

        let shared = binDir.appendingPathComponent("shared")
        let exclusive = binDir.appendingPathComponent("exclusive")
        try "a".write(to: shared, atomically: true, encoding: .utf8)
        try "b".write(to: exclusive, atomically: true, encoding: .utf8)

        let pkgA = PackageInfo(packageIdentifier: "com.example.tool", version: "1.0")
        let pkgB = PackageInfo(packageIdentifier: "com.example.other", version: "1.0")

        let stub = StubReceiptReader()
        stub.packages = [pkgA.packageIdentifier: pkgA, pkgB.packageIdentifier: pkgB]
        stub.contentsMap[pkgA.packageIdentifier] = PackageContents(files: [shared, exclusive], directories: [binDir])
        stub.contentsMap[pkgB.packageIdentifier] = PackageContents(files: [shared], directories: [binDir])

        let resolver = PackageResolver(receiptReader: stub)
        XCTAssertEqual(try resolver.resolve(target: "tool").packageIdentifier, pkgA.packageIdentifier)

        let guardInstance = SafetyGuard(customAllowedRoot: sandbox.rootURL)
        let scanner = PackageScanner(
            fileManager: fm,
            receiptReader: stub,
            safetyGuard: guardInstance,
            privilegeHandler: StubPrivilegeHandler(),
            customHomeDirectory: sandbox.userHomeURL
        )
        let scan = try scanner.scan(packageInfo: pkgA)
        XCTAssertEqual(scan.sharedFiles.count, 1)
        XCTAssertTrue(scan.items.contains { $0.url.standardized.path == exclusive.standardized.path })

        let remover = TrashRemover(
            fileManager: fm,
            safetyGuard: guardInstance,
            historyLogger: HistoryLogger(fileManager: fm, customManifestURL: sandbox.rootURL.appendingPathComponent("history.json")),
            privilegeHandler: StubPrivilegeHandler()
        )
        let plan = PackageRemovalPlan(packageInfo: pkgA, selectedItems: scan.items, isPermanent: true)
        let result = try remover.executePackageRemoval(plan: plan, receiptManager: stub)
        XCTAssertTrue(result.isCompleteSuccess)
        XCTAssertTrue(result.receiptForgotten)
        XCTAssertTrue(fm.fileExists(atPath: shared.path))
        XCTAssertFalse(fm.fileExists(atPath: exclusive.path))
    }
}
