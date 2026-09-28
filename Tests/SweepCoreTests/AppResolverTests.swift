import XCTest
@testable import SweepCore

final class AppResolverTests: XCTestCase {
    var sandbox: TestSandbox!

    override func setUpWithError() throws {
        sandbox = try TestSandbox()
    }

    override func tearDownWithError() throws {
        sandbox.cleanUp()
        sandbox = nil
    }

    func testResolveByBundleID() throws {
        _ = try DummyAppBuilder.createDummyApp(
            in: sandbox.applicationsURL,
            bundleName: "TestChat",
            bundleIdentifier: "com.example.testchat"
        )

        let resolver = AppResolver(customSearchDirectories: [sandbox.applicationsURL])
        let app = try resolver.resolve(target: "com.example.testchat")

        XCTAssertEqual(app.bundleName, "TestChat")
        XCTAssertEqual(app.bundleIdentifier, "com.example.testchat")
        XCTAssertEqual(app.vendorToken, "example")
    }

    func testResolveByAppName() throws {
        _ = try DummyAppBuilder.createDummyApp(
            in: sandbox.applicationsURL,
            bundleName: "TestCodeEditor",
            bundleIdentifier: "com.vendor.codeeditor"
        )

        let resolver = AppResolver(customSearchDirectories: [sandbox.applicationsURL])
        let app = try resolver.resolve(target: "TestCodeEditor")

        XCTAssertEqual(app.bundleIdentifier, "com.vendor.codeeditor")
    }

    func testResolveByDirectPath() throws {
        let appURL = try DummyAppBuilder.createDummyApp(
            in: sandbox.applicationsURL,
            bundleName: "DirectApp",
            bundleIdentifier: "com.direct.app"
        )

        let resolver = AppResolver(customSearchDirectories: [])
        let app = try resolver.resolve(target: appURL.path)

        XCTAssertEqual(app.bundleName, "DirectApp")
        XCTAssertEqual(app.bundleURL.path, appURL.path)
    }

    func testVendorTokenExtraction() {
        let resolver = AppResolver(customSearchDirectories: [])
        XCTAssertEqual(resolver.extractVendorToken(from: "com.tinyspeck.slackmacgap"), "tinyspeck")
        XCTAssertEqual(resolver.extractVendorToken(from: "org.mozilla.firefox"), "mozilla")
        XCTAssertEqual(resolver.extractVendorToken(from: "net.whatsapp.WhatsApp"), "whatsapp")
        XCTAssertNil(resolver.extractVendorToken(from: "single"))
        XCTAssertNil(resolver.extractVendorToken(from: "com.x")) // Too short
    }

    func testAppNotFoundThrowsError() {
        let resolver = AppResolver(customSearchDirectories: [sandbox.applicationsURL])
        XCTAssertThrowsError(try resolver.resolve(target: "DefinitelyNotInstalledApp")) { error in
            guard let sweepError = error as? SweepError else {
                XCTFail("Expected SweepError, got \(error)")
                return
            }
            XCTAssertEqual(sweepError.exitCode, .appNotFound)
        }
    }
}
