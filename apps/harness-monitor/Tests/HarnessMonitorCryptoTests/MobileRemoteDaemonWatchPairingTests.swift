import Foundation
import HarnessMonitorCrypto
import XCTest

final class MobileRemoteDaemonWatchPairingTests: XCTestCase {
  func testWatchPairingClaimsWithDedicatedDeviceIdentity() async throws {
    let now = Date(timeIntervalSince1970: 1_752_124_400)
    let identityStore = InMemoryMobileDeviceIdentityStore()
    let phoneIdentity = MobileDeviceIdentity(
      id: "default-mobile-device",
      displayName: "Bart's iPhone",
      signingPrivateKeyRawRepresentation: Data(repeating: 1, count: 32),
      agreementPrivateKeyRawRepresentation: Data(repeating: 2, count: 32),
      createdAt: now.addingTimeInterval(-60)
    )
    try await identityStore.save(phoneIdentity)
    let phoneCredential = try transferredPhoneCredential(identity: phoneIdentity, now: now)
    let credentialStore = InMemoryMobilePairedStationCredentialStore(
      credentials: [phoneCredential]
    )
    let transport = RecordingWatchRemotePairingTransport(pairedAt: now.addingTimeInterval(5))
    let coordinator = MobileRemoteDaemonPairingCoordinator(
      identityStore: identityStore,
      credentialStore: credentialStore,
      transport: transport,
      device: .watchOS
    )

    let credential = try await coordinator.pair(
      invitationURL: try watchRemoteInvitationURL(now: now),
      deviceName: "Bart's Apple Watch",
      now: now
    )

    let capturedRequest = await transport.lastRequest()
    let request = try XCTUnwrap(capturedRequest)
    XCTAssertEqual(request.platform, "watchos")
    XCTAssertEqual(request.displayName, "Bart's Apple Watch")
    XCTAssertTrue(request.clientID.hasPrefix("watchos-"))
    XCTAssertEqual(credential.deviceIdentityID, MobileRemoteDaemonPairingDevice.watchOS.identityID)
    XCTAssertEqual(credential.remoteDaemonAccess?.platform, "watchos")
    XCTAssertEqual(credential.remoteDaemonAccess?.clientID, request.clientID)
    XCTAssertEqual(
      credential.remoteDaemonAccess?.reviewsQuery?.repositories,
      ["smykla-skalski/harness"]
    )
    let storedWatchIdentity = try await identityStore.load(
      id: MobileRemoteDaemonPairingDevice.watchOS.identityID
    )
    let storedPhoneIdentity = try await identityStore.load(id: phoneIdentity.id)
    XCTAssertNotNil(storedWatchIdentity)
    XCTAssertNil(storedPhoneIdentity)
  }

  func testWatchPairingKeepsTransferredIdentityUsedByAnotherStation() async throws {
    let now = Date(timeIntervalSince1970: 1_752_124_400)
    let phoneIdentity = MobileDeviceIdentity(
      id: "default-mobile-device",
      displayName: "Bart's iPhone",
      signingPrivateKeyRawRepresentation: Data(repeating: 1, count: 32),
      agreementPrivateKeyRawRepresentation: Data(repeating: 2, count: 32),
      createdAt: now.addingTimeInterval(-60)
    )
    let replacedCredential = try transferredPhoneCredential(identity: phoneIdentity, now: now)
    var retainedCredential = replacedCredential
    retainedCredential.stationID = "remote-daemon-secondary"
    retainedCredential.stationName = "secondary.example.com"
    let identityStore = InMemoryMobileDeviceIdentityStore(identities: [phoneIdentity])
    let credentialStore = InMemoryMobilePairedStationCredentialStore(
      credentials: [replacedCredential, retainedCredential]
    )
    let coordinator = MobileRemoteDaemonPairingCoordinator(
      identityStore: identityStore,
      credentialStore: credentialStore,
      transport: RecordingWatchRemotePairingTransport(pairedAt: now),
      device: .watchOS
    )

    _ = try await coordinator.pair(
      invitationURL: try watchRemoteInvitationURL(now: now),
      deviceName: "Bart's Apple Watch",
      now: now
    )

    let storedPhoneIdentity = try await identityStore.load(id: phoneIdentity.id)
    XCTAssertEqual(storedPhoneIdentity, phoneIdentity)
  }
}

private actor RecordingWatchRemotePairingTransport: MobileRemoteDaemonPairingTransport {
  struct Request: Sendable {
    var clientID: String
    var displayName: String
    var platform: String
  }

  private let pairedAt: Date
  private var request: Request?

  init(pairedAt: Date) {
    self.pairedAt = pairedAt
  }

  func claim(
    invitation: MobileRemoteDaemonPairingInvitation,
    clientID: String,
    displayName: String,
    platform: String
  ) async throws -> MobileRemoteDaemonPairingClaim {
    request = Request(clientID: clientID, displayName: displayName, platform: platform)
    return MobileRemoteDaemonPairingClaim(
      clientID: clientID,
      displayName: displayName,
      platform: platform,
      role: .operator,
      scopes: ["read", "write"],
      token: "watch-server-token",
      tokenHint: "watch123",
      pairedAt: pairedAt,
      reviewsQuery: MobileRemoteDaemonReviewsQuery(
        repositories: ["smykla-skalski/harness"],
        cacheMaxAgeSeconds: 45
      )
    )
  }

  func lastRequest() -> Request? {
    request
  }
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

private func transferredPhoneCredential(
  identity: MobileDeviceIdentity,
  now: Date
) throws -> MobilePairedStationCredential {
  let endpoint = URL(string: "https://daemon.example.com")!
  let pin = try MobileRemoteDaemonSPKIPin(
    validating: "sha256/CQ8Rnn313xPUG+5zny4xTooD6AxAsZr/anC/ea4bTIY="
  )
  return MobilePairedStationCredential(
    stationID: "remote-daemon-example-com",
    stationName: "daemon.example.com",
    endpoint: endpoint,
    stationPublicKeyFingerprint: pin.value,
    deviceIdentityID: identity.id,
    snapshotKeyID: "",
    commandKeyID: "",
    symmetricKeyRawRepresentation: Data(),
    pairedAt: now.addingTimeInterval(-30),
    defaultStation: true,
    remoteDaemonAccess: MobileRemoteDaemonAccess(
      endpoint: endpoint,
      clientID: "ios-client",
      displayName: identity.displayName,
      platform: "ios",
      role: .operator,
      scopes: ["read", "write"],
      bearerToken: "phone-server-token",
      tokenHint: "phone123",
      serverSPKISHA256: pin,
      pairedAt: now.addingTimeInterval(-30)
    )
  )
}
