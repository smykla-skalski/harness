import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto
import XCTest

final class MobileRemoteDaemonPairingTests: XCTestCase {
  func testPairingLinkDecodesRemoteInvitation() throws {
    let now = Date(timeIntervalSince1970: 1_752_124_400)

    let link = try MobilePairingLink.decode(remoteInvitationURL(now: now), now: now)
    guard case .remote(let invitation) = link else {
      return XCTFail("expected remote daemon invitation")
    }

    XCTAssertEqual(invitation.endpoint.absoluteString, "https://daemon.example.com")
    XCTAssertEqual(invitation.code, "one-time-code")
    XCTAssertEqual(invitation.role, .operator)
    XCTAssertEqual(invitation.scopes, ["read", "write"])
    XCTAssertEqual(link.stationName, "daemon.example.com")
  }

  func testManualPayloadNormalizesRemoteAndRelayInvitations() throws {
    let now = Date(timeIntervalSince1970: 1_752_124_400)
    let remoteURL = try remoteInvitationURL(now: now)
    let relayInvitation = makePairingInvitation(now: now)
    let relayURL = try MobilePairingInvitationCodec.encode(relayInvitation)

    let normalizedRemote = try MobilePairingLink.normalizedURL(
      from: pairingPayload(from: remoteURL),
      now: now
    )
    let normalizedRelay = try MobilePairingLink.normalizedURL(
      from: pairingPayload(from: relayURL),
      now: now
    )

    XCTAssertEqual(
      try MobilePairingLink.decode(normalizedRemote, now: now),
      try MobilePairingLink.decode(remoteURL, now: now)
    )
    XCTAssertEqual(
      try MobilePairingLink.decode(normalizedRelay, now: now),
      .relay(relayInvitation)
    )
  }

  func testCoordinatorPersistsRemoteBearerCredential() async throws {
    let now = Date(timeIntervalSince1970: 1_752_124_400)
    let identityStore = InMemoryMobileDeviceIdentityStore()
    let credentialStore = InMemoryMobilePairedStationCredentialStore()
    let transport = RecordingRemotePairingTransport(
      claim: MobileRemoteDaemonPairingClaim(
        clientID: "ios-identity-fingerprint",
        displayName: "Bart's iPhone",
        platform: "ios",
        role: .operator,
        scopes: ["read", "write"],
        token: "server-issued-token",
        tokenHint: "abcd1234",
        pairedAt: now.addingTimeInterval(5)
      )
    )
    let coordinator = MobileRemoteDaemonPairingCoordinator(
      identityStore: identityStore,
      credentialStore: credentialStore,
      transport: transport,
      platform: "ios"
    )

    let credential = try await coordinator.pair(
      invitationURL: remoteInvitationURL(now: now),
      deviceName: "Bart's iPhone",
      now: now
    )

    let capturedRequest = await transport.lastRequest()
    let request = try XCTUnwrap(capturedRequest)
    XCTAssertEqual(request.displayName, "Bart's iPhone")
    XCTAssertEqual(request.platform, "ios")
    XCTAssertTrue(request.clientID.hasPrefix("ios-"))
    XCTAssertEqual(credential.remoteDaemonAccess?.bearerToken, "server-issued-token")
    XCTAssertEqual(credential.remoteDaemonAccess?.serverSPKISHA256.value, testSPKIPin)
    XCTAssertTrue(credential.symmetricKeyRawRepresentation.isEmpty)
    XCTAssertTrue(credential.snapshotKeyID.isEmpty)
    let storedCredential = try await credentialStore.load(stationID: credential.stationID)
    XCTAssertEqual(storedCredential, credential)
    let storedIdentity = try await identityStore.load(
      id: MobileRemoteDaemonPairingCoordinator<RecordingRemotePairingTransport>.identityID
    )
    XCTAssertNotNil(storedIdentity)
  }

  func testRepairingRemoteStationPreservesDefaultSelection() async throws {
    let now = Date(timeIntervalSince1970: 1_752_124_400)
    let existingRemote = MobilePairedStationCredential(
      stationID: "remote-daemon-example-com",
      stationName: "daemon.example.com",
      endpoint: URL(string: "https://daemon.example.com")!,
      stationPublicKeyFingerprint: testSPKIPin,
      deviceIdentityID: "default-mobile-device",
      snapshotKeyID: "",
      commandKeyID: "",
      symmetricKeyRawRepresentation: Data(),
      pairedAt: now.addingTimeInterval(-600),
      defaultStation: true,
      remoteDaemonAccess: try remoteAccess()
    )
    let otherStation = makePairedStationCredential(
      stationID: "station-other",
      deviceIdentityID: "default-mobile-device",
      now: now
    )
    let credentialStore = InMemoryMobilePairedStationCredentialStore(
      credentials: [existingRemote, otherStation]
    )
    let transport = RecordingRemotePairingTransport(
      claim: MobileRemoteDaemonPairingClaim(
        clientID: "ios-new-fingerprint",
        displayName: "Bart's iPhone",
        platform: "ios",
        role: .operator,
        scopes: ["read", "write"],
        token: "rotated-server-token",
        tokenHint: "dcba4321",
        pairedAt: now
      )
    )
    let coordinator = MobileRemoteDaemonPairingCoordinator(
      identityStore: InMemoryMobileDeviceIdentityStore(),
      credentialStore: credentialStore,
      transport: transport,
      platform: "ios"
    )

    let credential = try await coordinator.pair(
      invitationURL: remoteInvitationURL(now: now),
      deviceName: "Bart's iPhone",
      now: now
    )

    XCTAssertTrue(credential.defaultStation)
    XCTAssertEqual(credential.remoteDaemonAccess?.bearerToken, "rotated-server-token")
  }

  func testRemoteAccessDebugDescriptionRedactsBearerToken() throws {
    let access = try remoteAccess()

    let description = String(describing: access)

    XCTAssertFalse(description.contains("server-issued-token"))
    XCTAssertTrue(description.contains("abcd1234"))
  }

  func testCredentialDebugDescriptionRedactsRemoteBearerToken() throws {
    let credential = MobilePairedStationCredential(
      stationID: "remote-daemon-example-com",
      stationName: "daemon.example.com",
      endpoint: URL(string: "https://daemon.example.com")!,
      stationPublicKeyFingerprint: testSPKIPin,
      deviceIdentityID: "default-mobile-device",
      snapshotKeyID: "",
      commandKeyID: "",
      symmetricKeyRawRepresentation: Data(),
      pairedAt: Date(timeIntervalSince1970: 1_752_124_405),
      remoteDaemonAccess: try remoteAccess()
    )

    XCTAssertFalse(String(describing: credential).contains("server-issued-token"))
  }

  func testKeychainRoundTripsAndRotatesRemoteBearerToken() async throws {
    let stationID = "remote-keychain-\(UUID().uuidString)"
    let store = KeychainMobilePairedStationCredentialStore(
      service: "io.harnessmonitor.tests.remote-mobile.\(UUID().uuidString)"
    )
    addTeardownBlock {
      try await store.delete(stationID: stationID)
    }
    var credential = MobilePairedStationCredential(
      stationID: stationID,
      stationName: "daemon.example.com",
      endpoint: URL(string: "https://daemon.example.com")!,
      stationPublicKeyFingerprint: testSPKIPin,
      deviceIdentityID: "default-mobile-device",
      snapshotKeyID: "",
      commandKeyID: "",
      symmetricKeyRawRepresentation: Data(),
      pairedAt: Date(timeIntervalSince1970: 1_752_124_405),
      remoteDaemonAccess: try remoteAccess()
    )

    try await store.save(credential)
    let stored = try await store.load(stationID: stationID)
    XCTAssertEqual(stored?.remoteDaemonAccess?.bearerToken, "server-issued-token")

    credential.remoteDaemonAccess?.bearerToken = "rotated-server-token"
    try await store.save(credential)
    let rotated = try await store.load(stationID: stationID)
    XCTAssertEqual(rotated?.remoteDaemonAccess?.bearerToken, "rotated-server-token")
  }

  func testInvitationRejectsExpiredAndNonHTTPSProfiles() throws {
    let now = Date(timeIntervalSince1970: 1_752_124_400)

    XCTAssertThrowsError(
      try MobileRemoteDaemonPairingInvitation.decode(
        remoteInvitationURL(now: now, endpoint: "https://daemon.example.com", ttl: -1),
        now: now
      )
    ) { error in
      XCTAssertEqual(error as? MobileRemoteDaemonProfileError, .expired)
    }
    XCTAssertThrowsError(
      try MobileRemoteDaemonPairingInvitation.decode(
        remoteInvitationURL(now: now, endpoint: "http://daemon.example.com"),
        now: now
      )
    ) { error in
      XCTAssertEqual(error as? MobileRemoteDaemonProfileError, .invalidEndpoint)
    }
  }

  func testWatchTransferRoundTripsRemoteDaemonAccess() throws {
    let now = Date(timeIntervalSince1970: 1_752_124_400)
    let identity = MobileDeviceIdentity(
      id: "default-mobile-device",
      displayName: "Bart's iPhone",
      signingPrivateKeyRawRepresentation: Data(repeating: 1, count: 32),
      agreementPrivateKeyRawRepresentation: Data(repeating: 2, count: 32),
      createdAt: now
    )
    let credential = MobilePairedStationCredential(
      stationID: "remote-daemon-example-com",
      stationName: "daemon.example.com",
      endpoint: URL(string: "https://daemon.example.com")!,
      stationPublicKeyFingerprint: testSPKIPin,
      deviceIdentityID: identity.id,
      snapshotKeyID: "",
      commandKeyID: "",
      symmetricKeyRawRepresentation: Data(),
      pairedAt: now,
      defaultStation: true,
      remoteDaemonAccess: try remoteAccess()
    )
    let transfer = MobileWatchPairingTransfer(
      identities: [identity],
      credentials: [credential],
      exportedAt: now.addingTimeInterval(10)
    )

    let decoded = try MobileWatchPairingTransfer.decode(try transfer.encodedData())

    XCTAssertEqual(decoded.credentials.first?.remoteDaemonAccess, credential.remoteDaemonAccess)
    XCTAssertEqual(decoded, transfer)
  }
}

private actor RecordingRemotePairingTransport: MobileRemoteDaemonPairingTransport {
  struct Request: Sendable {
    var clientID: String
    var displayName: String
    var platform: String
  }

  private let claim: MobileRemoteDaemonPairingClaim
  private var request: Request?

  init(claim: MobileRemoteDaemonPairingClaim) {
    self.claim = claim
  }

  func claim(
    invitation: MobileRemoteDaemonPairingInvitation,
    clientID: String,
    displayName: String,
    platform: String
  ) async throws -> MobileRemoteDaemonPairingClaim {
    request = Request(clientID: clientID, displayName: displayName, platform: platform)
    return claim
  }

  func lastRequest() -> Request? {
    request
  }
}

private let testSPKIPin = "sha256/CQ8Rnn313xPUG+5zny4xTooD6AxAsZr/anC/ea4bTIY="

private func remoteInvitationURL(
  now: Date,
  endpoint: String = "https://daemon.example.com",
  ttl: TimeInterval = 600
) throws -> URL {
  let payload: [String: Any] = [
    "version": 1,
    "endpoint": endpoint,
    "code": "one-time-code",
    "server_spki_sha256": testSPKIPin,
    "role": "operator",
    "scopes": ["read", "write"],
    "expires_at": ISO8601DateFormatter().string(from: now.addingTimeInterval(ttl)),
  ]
  let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
  let encoded =
    data.base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
  return try XCTUnwrap(URL(string: "harness://remote-pair?payload=\(encoded)"))
}

private func remoteAccess() throws -> MobileRemoteDaemonAccess {
  MobileRemoteDaemonAccess(
    endpoint: URL(string: "https://daemon.example.com")!,
    clientID: "ios-identity-fingerprint",
    displayName: "Bart's iPhone",
    platform: "ios",
    role: .operator,
    scopes: ["read", "write"],
    bearerToken: "server-issued-token",
    tokenHint: "abcd1234",
    serverSPKISHA256: try MobileRemoteDaemonSPKIPin(validating: testSPKIPin),
    pairedAt: Date(timeIntervalSince1970: 1_752_124_405)
  )
}

private func pairingPayload(from url: URL) throws -> String {
  let payload = URLComponents(url: url, resolvingAgainstBaseURL: false)?
    .queryItems?
    .first { $0.name == "payload" }?
    .value
  return try XCTUnwrap(payload)
}
