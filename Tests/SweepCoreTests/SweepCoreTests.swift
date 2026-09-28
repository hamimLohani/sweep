import XCTest
@testable import SweepCore

final class SweepCoreTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertFalse(SearchRuleLoader.defaultRules.isEmpty)
    }
}
