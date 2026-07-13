import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto
import HarnessMonitorMirrorStore
import XCTest

@MainActor
final class WatchRemoteDaemonPairingPayloadTests: XCTestCase {
  func testWatchPairsDirectlyFromRemotePayload() async throws {
    let now = Date(timeIntervalSince1970: 1_752_124_400)
    let identityStore = InMemoryMobileDeviceIdentityStore()
    let credentialStore = InMemoryMobilePairedStationCredentialStore()
    let pairer = RecordingWatchCredentialPairer(
      identityStore: identityStore,
      credentialStore: credentialStore,
      credential: try watchRemoteCredential(now: now)
    )
    let store = MirrorStore(
      demoModeEnabled: true,
      profile: .watch,
      identityStore: identityStore,
      credentialStore: credentialStore,
      syncClientFactory: WatchPairingSyncClientFactory(),
      pairer: pairer,
      sharedSnapshotStore: nil
    )
    let invitationURL = try watchRemoteInvitationURL(now: now)

    let paired = await store.pairDirectWatchDaemon(
      payload: invitationURL.absoluteString,
      deviceName: "Bart's Apple Watch",
      now: now
    )

    let capturedRequest = await pairer.lastRequest()
    let request = try XCTUnwrap(capturedRequest)
    XCTAssertTrue(paired)
    XCTAssertEqual(request.invitationURL, invitationURL)
    XCTAssertEqual(request.deviceName, "Bart's Apple Watch")
    XCTAssertEqual(request.now, now)
    XCTAssertFalse(store.demoModeEnabled)
    XCTAssertTrue(
      store.pairedCredentials.contains(where: MobileRemoteDaemonPairingDevice.watchOS.owns)
    )
  }

  func testWatchRejectsNonRemotePairingPayload() async throws {
    let pairer = RecordingWatchCredentialPairer(
      identityStore: InMemoryMobileDeviceIdentityStore(),
      credentialStore: InMemoryMobilePairedStationCredentialStore(),
      credential: try watchRemoteCredential(now: .now)
    )
    let store = MirrorStore(
      demoModeEnabled: false,
      profile: .watch,
      pairer: pairer,
      sharedSnapshotStore: nil
    )

    let paired = await store.pairDirectWatchDaemon(
      payload: "harness://pair?payload=not-a-remote-invitation",
      deviceName: "Bart's Apple Watch"
    )

    XCTAssertFalse(paired)
    let capturedRequest = await pairer.lastRequest()
    XCTAssertNil(capturedRequest)
  }

  func testFailedReplacementDoesNotReportExistingWatchPairingAsSuccess() async throws {
    let now = Date(timeIntervalSince1970: 1_752_124_400)
    let identity = MobileDeviceIdentity(
      id: MobileRemoteDaemonPairingDevice.watchOS.identityID,
      displayName: "Bart's Apple Watch",
      createdAt: now.addingTimeInterval(-60)
    )
    let credential = try watchRemoteCredential(now: now.addingTimeInterval(-30))
    let identityStore = InMemoryMobileDeviceIdentityStore(identities: [identity])
    let credentialStore = InMemoryMobilePairedStationCredentialStore(
      credentials: [credential]
    )
    let store = MirrorStore(
      demoModeEnabled: false,
      profile: .watch,
      identityStore: identityStore,
      credentialStore: credentialStore,
      syncClientFactory: WatchPairingSyncClientFactory(),
      pairer: FailingWatchCredentialPairer(),
      sharedSnapshotStore: nil
    )
    await store.loadStoredPairings()

    let paired = await store.pairDirectWatchDaemon(
      payload: try watchRemoteInvitationURL(now: now).absoluteString,
      deviceName: "Bart's Apple Watch",
      now: now
    )

    XCTAssertFalse(paired)
    XCTAssertEqual(store.pairedCredentials, [credential])
  }

  func testWatchForwardsSelectedCloudFallbackAmongMultipleStations() async throws {
    let now = Date(timeIntervalSince1970: 1_752_124_400)
    let phoneIdentity = MobileDeviceIdentity(
      id: "phone-identity",
      displayName: "Bart's iPhone",
      createdAt: now.addingTimeInterval(-600)
    )
    let studio = watchCloudCredential(
      stationID: "station-studio",
      identityID: phoneIdentity.id,
      defaultStation: true,
      now: now.addingTimeInterval(-300)
    )
    let laptop = watchCloudCredential(
      stationID: "station-laptop",
      identityID: phoneIdentity.id,
      defaultStation: false,
      now: now.addingTimeInterval(-200)
    )
    let identityStore = InMemoryMobileDeviceIdentityStore(identities: [phoneIdentity])
    let credentialStore = InMemoryMobilePairedStationCredentialStore(
      credentials: [studio, laptop]
    )
    let pairer = RecordingWatchCredentialPairer(
      identityStore: identityStore,
      credentialStore: credentialStore,
      credential: try watchRemoteCredential(now: now)
    )
    let store = MirrorStore(
      demoModeEnabled: false,
      profile: .watch,
      identityStore: identityStore,
      credentialStore: credentialStore,
      syncClientFactory: WatchPairingSyncClientFactory(),
      pairer: pairer,
      sharedSnapshotStore: nil
    )
    await store.loadStoredPairings()
    store.selectedStationID = laptop.stationID

    let paired = await store.pairDirectWatchDaemon(
      payload: try watchRemoteInvitationURL(now: now).absoluteString,
      deviceName: "Bart's Apple Watch",
      now: now
    )

    XCTAssertTrue(paired)
    let capturedRequest = await pairer.lastRequest()
    XCTAssertEqual(capturedRequest?.cloudFallbackStationID, laptop.stationID)
  }
}

private struct FailingWatchCredentialPairer: MobileMonitorCredentialPairer {
  func pair(
    invitationURL: URL,
    deviceName: String,
    cloudFallbackStationID: String?,
    now: Date
  ) async throws -> MobilePairedStationCredential {
    throw WatchPairingTestError.claimFailed
  }
}

private enum WatchPairingTestError: Error {
  case claimFailed
}

private actor RecordingWatchCredentialPairer: MobileMonitorCredentialPairer {
  struct Request: Sendable {
    var invitationURL: URL
    var deviceName: String
    var cloudFallbackStationID: String?
    var now: Date
  }

  private let identityStore: any MobileDeviceIdentityStore
  private let credentialStore: any MobilePairedStationCredentialStore
  private let credential: MobilePairedStationCredential
  private var request: Request?

  init(
    identityStore: any MobileDeviceIdentityStore,
    credentialStore: any MobilePairedStationCredentialStore,
    credential: MobilePairedStationCredential
  ) {
    self.identityStore = identityStore
    self.credentialStore = credentialStore
    self.credential = credential
  }

  func pair(
    invitationURL: URL,
    deviceName: String,
    cloudFallbackStationID: String?,
    now: Date
  ) async throws -> MobilePairedStationCredential {
    request = Request(
      invitationURL: invitationURL,
      deviceName: deviceName,
      cloudFallbackStationID: cloudFallbackStationID,
      now: now
    )
    try await identityStore.save(
      MobileDeviceIdentity(
        id: credential.deviceIdentityID,
        displayName: deviceName,
        createdAt: now
      )
    )
    try await credentialStore.save(credential)
    return credential
  }

  func lastRequest() -> Request? {
    request
  }
}

private struct WatchPairingSyncClientFactory: MobileMonitorSyncClientFactory {
  func makeSyncClient(
    credential: MobilePairedStationCredential,
    identity: MobileDeviceIdentity
  ) -> any MobileMonitorSyncClient {
    WatchPairingSyncClient()
  }
}

private struct WatchPairingSyncClient: MobileMonitorSyncClient {
  func fetchLatestSnapshot(stationID: String, now: Date) async throws -> MobileMirrorSnapshot? {
    MobileMirrorSnapshot(
      schemaVersion: 1,
      revision: 1,
      generatedAt: now,
      expiresAt: now.addingTimeInterval(60),
      stations: [],
      attention: [],
      sessions: [],
      reviews: [],
      commands: []
    )
  }

  func queueCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileCommandSubmission {
    throw MobileRemoteDaemonSyncError.commandsUnavailable
  }

  func cancelCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileCommandReceipt {
    throw MobileRemoteDaemonSyncError.commandsUnavailable
  }
}

private func watchRemoteCredential(now: Date) throws -> MobilePairedStationCredential {
  let endpoint = URL(string: "https://daemon.example.com")!
  let pin = try MobileRemoteDaemonSPKIPin(
    validating: "sha256/CQ8Rnn313xPUG+5zny4xTooD6AxAsZr/anC/ea4bTIY="
  )
  return MobilePairedStationCredential(
    stationID: "remote-daemon-example-com",
    stationName: "daemon.example.com",
    endpoint: endpoint,
    stationPublicKeyFingerprint: pin.value,
    deviceIdentityID: MobileRemoteDaemonPairingDevice.watchOS.identityID,
    snapshotKeyID: "",
    commandKeyID: "",
    symmetricKeyRawRepresentation: Data(),
    pairedAt: now,
    defaultStation: true,
    remoteDaemonAccess: MobileRemoteDaemonAccess(
      endpoint: endpoint,
      clientID: "watchos-client",
      displayName: "Bart's Apple Watch",
      platform: MobileRemoteDaemonPairingDevice.watchOS.platform,
      role: .operator,
      scopes: ["read", "write"],
      bearerToken: "watch-server-token",
      tokenHint: "watch123",
      serverSPKISHA256: pin,
      pairedAt: now
    )
  )
}

private func watchCloudCredential(
  stationID: String,
  identityID: String,
  defaultStation: Bool,
  now: Date
) -> MobilePairedStationCredential {
  MobilePairedStationCredential(
    stationID: stationID,
    stationName: stationID,
    endpoint: URL(string: "https://\(stationID).local/pair")!,
    stationPublicKeyFingerprint: "00:11:22:33:44:55:66:77",
    deviceIdentityID: identityID,
    snapshotKeyID: "snapshot-key",
    commandKeyID: "command-key",
    symmetricKeyRawRepresentation: Data(repeating: 3, count: 32),
    pairedAt: now,
    defaultStation: defaultStation
  )
}

private func watchRemoteInvitationURL(now: Date) throws -> URL {
  let payload: [String: Any] = [
    "version": 1,
    "endpoint": "https://daemon.example.com",
    "code": "watch-one-time-code",
    "server_spki_sha256": "sha256/CQ8Rnn313xPUG+5zny4xTooD6AxAsZr/anC/ea4bTIY=",
    "role": "operator",
    "scopes": ["read", "write"],
    "expires_at": ISO8601DateFormatter().string(from: now.addingTimeInterval(600)),
  ]
  let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
  let encoded =
    data.base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
  return try XCTUnwrap(URL(string: "harness://remote-pair?payload=\(encoded)"))
}
