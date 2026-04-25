import XCTest
@testable import HarnessMonitorE2ECore

final class HarnessClientTests: XCTestCase {
    func testMergedEnvironmentBindsDataHomeToBothXDGAndDaemonKeys() {
        let dataHome = URL(fileURLWithPath: "/tmp/agents-e2e-data-home")
        let client = HarnessClient(
            binary: URL(fileURLWithPath: "/usr/bin/true"),
            dataHome: dataHome
        )

        let env = client.mergedEnvironment()

        XCTAssertEqual(env["XDG_DATA_HOME"], dataHome.path)
        XCTAssertEqual(env["HARNESS_DAEMON_DATA_HOME"], dataHome.path)
        XCTAssertEqual(env["XDG_DATA_HOME"], env["HARNESS_DAEMON_DATA_HOME"])
    }

    func testMergedEnvironmentExtraOverridesAreApplied() {
        let dataHome = URL(fileURLWithPath: "/tmp/agents-e2e-data-home")
        let client = HarnessClient(
            binary: URL(fileURLWithPath: "/usr/bin/true"),
            dataHome: dataHome
        )

        let env = client.mergedEnvironment(extra: ["HARNESS_DAEMON_DATA_HOME": "/override"])

        XCTAssertEqual(env["HARNESS_DAEMON_DATA_HOME"], "/override")
        XCTAssertEqual(env["XDG_DATA_HOME"], dataHome.path)
    }
}
