import XCTest

@testable import HarnessKit

final class DaemonModelsTests: XCTestCase {
  func testLaunchAgentLifecycleCaptionIncludesStableStatusParts() {
    let status = LaunchAgentStatus(
      installed: true,
      loaded: true,
      label: "io.harness.daemon",
      path: "/tmp/io.harness.daemon.plist",
      domainTarget: "gui/501",
      serviceTarget: "gui/501/io.harness.daemon",
      state: "running",
      pid: 4_242,
      lastExitStatus: 0
    )

    let caption = status.lifecycleCaption
    XCTAssertTrue(caption.contains("gui/501/io.harness.daemon"))
    XCTAssertTrue(caption.contains("pid 4242"))
    XCTAssertTrue(caption.contains("exit 0"))
  }
}
