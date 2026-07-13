import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto
import HarnessMonitorMirrorStore
import XCTest

@MainActor
final class MirrorStorePairingFeedbackTests: XCTestCase {
  func testPairingStoreFailureStaysVisibleWithRecoveryInstructions() async throws {
    let now = Date()
    let store = MirrorStore(
      pairer: PairingStoreUnavailablePairer(),
      sharedSnapshotStore: nil
    )

    await store.handleOpenURL(try remoteInvitationURL(now: now), deviceName: "Bart's iPhone")

    XCTAssertEqual(store.syncStatus, pairingStoreUnavailableStatus)

    await store.refresh()

    XCTAssertEqual(store.syncStatus, .unpaired)
    XCTAssertEqual(store.presentedSyncStatus, pairingStoreUnavailableStatus)
  }

  func testLiveRefreshWinsOverPriorPairingFailure() async throws {
    let now = Date()
    let store = MirrorStore(
      syncClient: SuccessfulPairingFeedbackRefreshClient(),
      pairer: PairingStoreUnavailablePairer(),
      sharedSnapshotStore: nil
    )

    await store.handleOpenURL(try remoteInvitationURL(now: now), deviceName: "Test iPhone")
    await store.refresh()

    guard case .live = store.syncStatus else {
      return XCTFail("expected a successful refresh, got \(store.syncStatus)")
    }
    XCTAssertEqual(store.presentedSyncStatus, store.syncStatus)
    XCTAssertEqual(store.pairingFailureStatus, pairingStoreUnavailableStatus)
  }
}

private let pairingStoreUnavailableStatus = MirrorSyncStatus.pairingFailed(
  "The remote daemon could not access its pairing store (HTTP 503). "
    + "This device may already be registered; revoke the existing client on the server, "
    + "then create a new pairing link."
)

private struct SuccessfulPairingFeedbackRefreshClient: MobileMonitorSyncClient {
  func fetchLatestSnapshot(stationID: String, now: Date) async throws -> MobileMirrorSnapshot? {
    .empty()
  }

  func queueCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileCommandSubmission {
    throw MobileRemoteDaemonPairingError.invalidResponse
  }

  func cancelCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileCommandReceipt {
    throw MobileRemoteDaemonPairingError.invalidResponse
  }
}

private struct PairingStoreUnavailablePairer: MobileMonitorCredentialPairer {
  func pair(
    invitationURL: URL,
    deviceName: String,
    cloudFallbackStationID: String?,
    now: Date
  ) async throws -> MobilePairedStationCredential {
    throw MobileRemoteDaemonPairingError.serverStatus(503)
  }
}

private struct RemoteInvitationPayload: Encodable {
  let version = 1
  let endpoint = "https://daemon.example.com"
  let code = "pairing-code"
  let serverSPKISHA256 = "sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  let role = "admin"
  let scopes = ["read", "write", "admin"]
  let expiresAt: Date

  enum CodingKeys: String, CodingKey {
    case version
    case endpoint
    case code
    case serverSPKISHA256 = "server_spki_sha256"
    case role
    case scopes
    case expiresAt = "expires_at"
  }
}

private func remoteInvitationURL(now: Date) throws -> URL {
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  let payload = try encoder.encode(
    RemoteInvitationPayload(expiresAt: now.addingTimeInterval(600))
  )
  let encoded = payload.base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
  var components = URLComponents()
  components.scheme = "harness"
  components.host = "remote-pair"
  components.queryItems = [URLQueryItem(name: "payload", value: encoded)]
  return try XCTUnwrap(components.url)
}
