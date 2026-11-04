import XCTest
@testable import MailDigestCore

final class ScaffoldTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(MailDigestCore.version, "0.1.0")
    }

    func testFixturesBundled() {
        XCTAssertNotNil(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    }
}
