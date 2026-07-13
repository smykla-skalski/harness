import Foundation
import HarnessMonitorCrypto
import XCTest

final class MobileRemoteDaemonPairingErrorTests: XCTestCase {
  func testStoreUnavailableExplainsHowToRecover() {
    let description = localizedDescription(for: .serverStatus(503))

    XCTAssertEqual(
      description,
      "The remote daemon could not access its pairing store (HTTP 503). "
        + "This device may already be registered; revoke the existing client on the server, "
        + "then create a new pairing link."
    )
  }

  func testPairingErrorsNeverExposeRawSwiftTypeNames() {
    let errors: [MobileRemoteDaemonPairingError] = [
      .invalidResponse,
      .serverStatus(403),
      .serverStatus(409),
      .serverStatus(410),
      .serverStatus(429),
      .serverStatus(500),
      .claimMismatch,
      .invalidCloudFallbackStation,
    ]

    for error in errors {
      let description = localizedDescription(for: error)
      XCTAssertFalse(description.isEmpty)
      XCTAssertFalse(description.contains("MobileRemoteDaemonPairingError"))
      XCTAssertFalse(description.contains("error 0"))
    }
  }

  private func localizedDescription(for error: MobileRemoteDaemonPairingError) -> String {
    (error as NSError).localizedDescription
  }
}
