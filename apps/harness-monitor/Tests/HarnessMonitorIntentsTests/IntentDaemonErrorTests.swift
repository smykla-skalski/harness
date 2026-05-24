import Foundation
import XCTest

@testable import HarnessMonitorIntents

final class IntentDaemonErrorTests: XCTestCase {
  func testDaemonUnavailableSurfacesFriendlyDescription() {
    let error = IntentDaemonError.daemonUnavailable(reason: "manifest stale")
    XCTAssertEqual(
      error.errorDescription,
      "Harness Monitor isn't reachable. Open it on your Mac and try again"
    )
    XCTAssertEqual(error.failureReason, "manifest stale")
  }

  func testManifestMalformedSurfacesFriendlyDescription() {
    let error = IntentDaemonError.manifestMalformed(path: "/x", reason: "json invalid")
    XCTAssertEqual(
      error.errorDescription,
      "Harness Monitor's connection info is corrupted. Restart the app and try again"
    )
    XCTAssertEqual(error.failureReason, "json invalid")
  }

  func testAuthTokenMissingSurfacesSignInPrompt() {
    let error = IntentDaemonError.authTokenMissing(path: "/x", reason: "missing")
    XCTAssertEqual(
      error.errorDescription,
      "Harness Monitor's credentials are missing. Open it on your Mac and sign in"
    )
  }

  func testFriendlyMessageMapsConnectionClosed() {
    XCTAssertEqual(
      IntentDaemonError.friendlyMessage(forRawRPCMessage: "WebSocket connection closed"),
      "Harness Monitor isn't reachable right now. Open it on your Mac and try again"
    )
  }

  func testFriendlyMessageMapsUpgradeRejected() {
    XCTAssertEqual(
      IntentDaemonError.friendlyMessage(forRawRPCMessage: "WebSocket upgrade rejected by server"),
      "Harness Monitor isn't reachable right now. Open it on your Mac and try again"
    )
  }

  func testFriendlyMessageMapsConnectionRefused() {
    XCTAssertEqual(
      IntentDaemonError.friendlyMessage(forRawRPCMessage: "Could not connect to the server"),
      "Harness Monitor isn't reachable right now. Open it on your Mac and try again"
    )
  }

  func testFriendlyMessageMapsRequestTimeout() {
    XCTAssertEqual(
      IntentDaemonError.friendlyMessage(
        forRawRPCMessage: "Daemon did not respond before the request timeout"
      ),
      "Harness Monitor took too long to respond. Try again in a moment"
    )
  }

  func testFriendlyMessageMapsUnauthorized() {
    XCTAssertEqual(
      IntentDaemonError.friendlyMessage(forRawRPCMessage: "unauthorized"),
      "Harness Monitor's credentials need refreshing. Open it on your Mac and sign in"
    )
  }

  func testFriendlyMessageFallsBackForUnknown() {
    XCTAssertEqual(
      IntentDaemonError.friendlyMessage(forRawRPCMessage: "something exploded"),
      "Harness Monitor couldn't complete the request. Try again in a moment"
    )
  }

  func testRPCFailedRoutesThroughFriendlyMessage() {
    let error = IntentDaemonError.rpcFailed(
      method: "reviews.query",
      message: "WebSocket connection closed"
    )
    XCTAssertEqual(
      error.errorDescription,
      "Harness Monitor isn't reachable right now. Open it on your Mac and try again"
    )
    XCTAssertEqual(
      error.failureReason,
      "rpc=reviews.query detail=WebSocket connection closed"
    )
  }
}
