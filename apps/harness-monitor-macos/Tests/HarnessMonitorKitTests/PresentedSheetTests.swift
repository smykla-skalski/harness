@testable import HarnessMonitorKit
import XCTest

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
}
