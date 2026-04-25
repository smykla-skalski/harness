import XCTest

@testable import HarnessMonitorE2ECore

final class ManifestTests: XCTestCase {
  func testRoundTripPreservesAllFields() throws {
    let manifest = E2EPreparedManifest(
      daemonPID: 123,
      bridgePID: 456,
      stateRoot: "/tmp/state",
      dataRoot: "/tmp/state/data-root",
      dataHome: "/tmp/state/data-root/data-home",
      daemonLog: "/tmp/state/logs/daemon.log",
      bridgeLog: "/tmp/state/logs/bridge.log",
      terminalSessionID: "sess-terminal",
      codexSessionID: "sess-codex",
      codexWorkspace: "/var/folders/.../wt",
      codexPort: 51234
    )
    let payload = try manifest.encoded()
    let decoded = try E2EPreparedManifest.decode(from: payload)
    XCTAssertEqual(decoded.daemonPID, manifest.daemonPID)
    XCTAssertEqual(decoded.bridgePID, manifest.bridgePID)
    XCTAssertEqual(decoded.codexPort, manifest.codexPort)
    XCTAssertEqual(decoded.codexWorkspace, manifest.codexWorkspace)
    XCTAssertEqual(decoded.dataHome, manifest.dataHome)
  }
}
