import XCTest
@testable import SweepCore

final class SafetyGuardTests: XCTestCase {
    var sandbox: TestSandbox!
    var guardInstance: SafetyGuard!

    override func setUpWithError() throws {
        sandbox = try TestSandbox()
        guardInstance = SafetyGuard(customAllowedRoot: sandbox.rootURL)
    }

    override func tearDownWithError() throws {
        sandbox.cleanUp()
        sandbox = nil
        guardInstance = nil
    }

    func testRejectsSystemPaths() {
        let systemPaths = [
            "/System/Library",
            "/usr/bin",
            "/bin/zsh",
            "/sbin/mount",
            "/private/etc/hosts",
            "/Library/Apple",
            "/Library/Keychains/System.keychain"
        ]

        for path in systemPaths {
            let url = URL(fileURLWithPath: path)
            XCTAssertThrowsError(try guardInstance.validate(itemURL: url)) { error in
                guard let sweepErr = error as? SweepError else {
                    XCTFail("Expected SweepError")
                    return
                }
                XCTAssertEqual(sweepErr.exitCode, .permissionError)
            }
        }
    }

    func testRejectsProtectedRootFolderNames() {
        let rootFolder = sandbox.userHomeURL.appendingPathComponent("Library/Application Support")
        XCTAssertThrowsError(try guardInstance.validate(itemURL: rootFolder)) { error in
            guard let sweepErr = error as? SweepError else {
                XCTFail("Expected SweepError")
                return
            }
            XCTAssertEqual(sweepErr.exitCode, .permissionError)
        }
    }

    func testRejectsSymlinkEscapesOutsideSandbox() throws {
        let insideURL = sandbox.userLibraryURL.appendingPathComponent("Caches/malicious_symlink")
        let targetOutside = URL(fileURLWithPath: "/etc/passwd")

        // Create symlink pointing outside
        try FileManager.default.createSymbolicLink(at: insideURL, withDestinationURL: targetOutside)

        XCTAssertThrowsError(try guardInstance.validate(itemURL: insideURL)) { error in
            guard let sweepErr = error as? SweepError else {
                XCTFail("Expected SweepError")
                return
            }
            XCTAssertEqual(sweepErr.exitCode, .permissionError)
        }
    }

    func testAcceptsSafeSandboxPaths() throws {
        let safeFile = sandbox.userLibraryURL.appendingPathComponent("Preferences/com.safe.app.plist")
        try "safe".write(to: safeFile, atomically: true, encoding: .utf8)

        XCTAssertNoThrow(try guardInstance.validate(itemURL: safeFile))
    }
}
