import XCTest
@testable import SweepCore

final class LeftoverScannerTests: XCTestCase {
    var sandbox: TestSandbox!

    override func setUpWithError() throws {
        sandbox = try TestSandbox()
    }

    override func tearDownWithError() throws {
        sandbox.cleanUp()
        sandbox = nil
    }

    func testDetectsHighMediumAndLowConfidenceLeftovers() throws {
        let bundleID = "com.samplecorp.musicplayer"
        let appName = "MusicPlayer"
        let vendor = "samplecorp"

        let appURL = try DummyAppBuilder.createDummyApp(
            in: sandbox.applicationsURL,
            bundleName: appName,
            bundleIdentifier: bundleID
        )

        try DummyAppBuilder.populateLeftovers(
            sandbox: sandbox,
            bundleIdentifier: bundleID,
            bundleName: appName,
            vendorToken: vendor
        )

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

        XCTAssertFalse(result.leftovers.isEmpty)

        // Verify High confidence: Containers and Preferences
        let highMatches = result.leftovers.filter { $0.confidence == .high }
        XCTAssertTrue(highMatches.contains { $0.url.lastPathComponent == "\(bundleID).plist" })
        XCTAssertTrue(highMatches.contains { $0.url.lastPathComponent == bundleID })

        // Verify Medium confidence: Application Support folder named MusicPlayer
        let medMatches = result.leftovers.filter { $0.confidence == .medium }
        XCTAssertTrue(medMatches.contains { $0.url.lastPathComponent == appName })

        // Verify Low confidence: Application Support folder named samplecorp
        let lowMatches = result.leftovers.filter { $0.confidence == .low }
        XCTAssertTrue(lowMatches.contains { $0.url.lastPathComponent == vendor })

        // Verify noise files are completely ignored
        XCTAssertFalse(result.leftovers.contains { $0.url.lastPathComponent.contains("UnrelatedSoftware") })
        XCTAssertFalse(result.leftovers.contains { $0.url.lastPathComponent.contains("com.unrelated.tool.plist") })
    }

    func testShortAppNameDoesNotMatchFalsePositives() {
        let shortAppInfo = AppInfo(
            bundleURL: URL(fileURLWithPath: "/tmp/Go.app"),
            bundleIdentifier: "org.golang.go",
            bundleName: "Go",
            displayName: "Go",
            executableName: "go",
            vendorToken: nil,
            version: "1.0",
            bundleSizeBytes: 500,
            isSystemApp: false
        )

        // Confidence scorer should reject 2-letter exact name matches to prevent catastrophes
        let match = ConfidenceScorer.score(itemName: "Go", appInfo: shortAppInfo, strategy: "bundleIdOrName")
        XCTAssertNil(match, "Short 2-letter app names must never trigger exact name folder matches")
    }

    func testAppleSystemAppThrowsProtectedError() throws {
        let systemAppInfo = AppInfo(
            bundleURL: URL(fileURLWithPath: "/System/Applications/Calculator.app"),
            bundleIdentifier: "com.apple.calculator",
            bundleName: "Calculator",
            displayName: "Calculator",
            executableName: "Calculator",
            vendorToken: "apple",
            version: "1.0",
            bundleSizeBytes: 1000,
            isSystemApp: true
        )

        let scanner = LeftoverScanner(customHomeDirectory: sandbox.userHomeURL)
        XCTAssertThrowsError(try scanner.scan(appInfo: systemAppInfo)) { error in
            guard let sweepError = error as? SweepError else {
                XCTFail("Expected SweepError")
                return
            }
            XCTAssertEqual(sweepError.exitCode, .permissionError)
        }
    }
}
