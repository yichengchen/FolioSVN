import XCTest
@testable import SVNClient

final class RepositoryPathTests: XCTestCase {
    func testNormalizesLeadingAndRepeatedSeparators() {
        XCTAssertEqual(RepositoryPath("/技术部//SDK/").value, "技术部/SDK")
    }

    func testRootPathIsEmpty() {
        XCTAssertEqual(RepositoryPath("/").value, "")
    }

    func testParentComponentsCannotEscapeRepositoryRoot() {
        XCTAssertEqual(RepositoryPath("../../技术部/旧版/../SDK").value, "技术部/SDK")
    }
}
