import XCTest
@testable import SVNClient

final class AppRuntimeEnvironmentTests: XCTestCase {
    func testHostedTestProcessIsRecognized() {
        XCTAssertTrue(AppRuntimeEnvironment.isRunningTests())
    }

    func testRecognizesXCTestConfigurationEnvironment() {
        XCTAssertTrue(AppRuntimeEnvironment.isRunningTests(environment: [
            "XCTestConfigurationFilePath": "/tmp/Test.xctestconfiguration"
        ]))
    }

    func testRecognizesXCTestSessionEnvironment() {
        XCTAssertTrue(AppRuntimeEnvironment.isRunningTests(environment: [
            "XCTestSessionIdentifier": UUID().uuidString
        ]))
    }

    func testNormalLaunchIsNotClassifiedAsTestRun() {
        XCTAssertFalse(AppRuntimeEnvironment.isRunningTests(environment: [:]))
    }
}
