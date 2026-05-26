import HarnessMonitorMirrorStore
import XCTest

final class WatchPairingSessionActivationTests: XCTestCase {
  func testSessionCreationActivates() {
    XCTAssertTrue(WatchPairingSessionActivation.shouldActivate(on: .sessionCreated))
  }

  func testSystemDeactivationReactivates() {
    XCTAssertTrue(WatchPairingSessionActivation.shouldActivate(on: .systemDeactivated))
  }

  func testPayloadPublishNeverActivates() {
    // Publishing pairing material runs on every mirror refresh. Re-activating an
    // already-activated WCSession here is what makes the WatchConnectivity daemon
    // log "already in progress or activated" on every refresh, so this must stay
    // false no matter how the publish path evolves.
    XCTAssertFalse(WatchPairingSessionActivation.shouldActivate(on: .payloadPublish))
  }
}
