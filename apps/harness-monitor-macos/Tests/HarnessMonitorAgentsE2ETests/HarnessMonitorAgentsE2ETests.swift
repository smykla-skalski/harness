import XCTest

@MainActor
final class HarnessMonitorAgentsE2ETests: HarnessMonitorUITestCase {
  override func setUpWithError() throws {
    try super.setUpWithError()
    throw XCTSkip("Agents e2e is temporarily disabled.")
  }

  func testTerminalAgentStartsAndStopsThroughSandboxedBridge() throws {}

  func testCodexThreadSteersAndApprovesThroughSandboxedBridge() throws {}
}
