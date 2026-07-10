import Foundation
import HarnessMonitorMirrorStore
import XCTest

final class MirrorSyncStatusTests: XCTestCase {
  func testSystemImageMatchesBothLegacyStores() {
    let expected: [(MirrorSyncStatus, String)] = [
      (.unpaired, "link.badge.plus"),
      (.demo, "testtube.2"),
      (.pairing("Studio"), "qrcode.viewfinder"),
      (.syncing, "arrow.triangle.2.circlepath"),
      (.live(.distantPast), "checkmark.icloud"),
      (.stale("expired"), "exclamationmark.icloud"),
      (.localNetworkDenied, "wifi.slash"),
      (.iCloudAccountUnavailable, "icloud.slash"),
      (.paired("Studio"), "key.horizontal"),
      (.privacy("done"), "checkmark.shield"),
      (.commandQueued(.distantPast), "checkmark.seal"),
      (.commandCompleted(.distantPast), "checkmark.circle"),
      (.commandCancelled(.distantPast), "xmark.seal"),
      (.commandFailed("boom"), "xmark.octagon"),
    ]
    for (status, image) in expected {
      XCTAssertEqual(status.systemImage, image, "\(status) should map to \(image)")
    }
  }

  func testIndicatesSyncFailureOnlyForSyncFailureCases() {
    let failures: [MirrorSyncStatus] = [
      .stale("expired"), .localNetworkDenied, .iCloudAccountUnavailable,
    ]
    for status in failures {
      XCTAssertTrue(status.indicatesSyncFailure, "\(status) is a sync failure")
    }
    let nonFailures: [MirrorSyncStatus] = [
      .unpaired, .demo, .pairing("S"), .syncing, .live(.distantPast), .paired("S"),
      .privacy("p"), .commandQueued(.distantPast), .commandCompleted(.distantPast),
      .commandCancelled(.distantPast), .commandFailed("boom"),
    ]
    for status in nonFailures {
      XCTAssertFalse(status.indicatesSyncFailure, "\(status) is not a sync failure")
    }
  }

  func testOpensAppSettingsOnlyForLocalNetworkDenied() {
    XCTAssertTrue(MirrorSyncStatus.localNetworkDenied.opensAppSettingsForRecovery)
    let others: [MirrorSyncStatus] = [
      .unpaired, .demo, .pairing("S"), .syncing, .live(.distantPast), .stale("e"),
      .iCloudAccountUnavailable, .paired("S"), .privacy("p"),
      .commandQueued(.distantPast), .commandCompleted(.distantPast),
      .commandCancelled(.distantPast), .commandFailed("b"),
    ]
    for status in others {
      XCTAssertFalse(status.opensAppSettingsForRecovery, "\(status) stays in-app")
    }
  }
}
