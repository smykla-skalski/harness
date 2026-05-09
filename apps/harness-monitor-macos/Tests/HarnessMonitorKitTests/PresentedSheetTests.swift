import XCTest

@testable import HarnessMonitorKit

final class PresentedSheetTests: XCTestCase {
  func testNewSessionCaseIsIdentifiable() {
    XCTAssertEqual(HarnessMonitorStore.PresentedSheet.newSession.id, "newSession")
  }

  func testSendSignalCaseStillWorks() {
    XCTAssertEqual(
      HarnessMonitorStore.PresentedSheet.sendSignal(agentID: "a").id,
      "sendSignal:a"
    )
  }

  func testNewCodexAgentCaseIsIdentifiable() {
    XCTAssertEqual(
      HarnessMonitorStore.PresentedSheet.newCodexAgent(sessionID: "sess-1").id,
      "newCodexAgent:sess-1"
    )
  }
}
