import CryptoKit
import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto
import XCTest

final class MobilePairingTests: XCTestCase {
  func testPairingInvitationCodecRoundTripsURLPayload() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let invitation = makeInvitation(now: now)

    let url = try MobilePairingInvitationCodec.encode(invitation)
    let decoded = try MobilePairingInvitationCodec.decode(url, now: now)

    XCTAssertEqual(url.scheme, "harness")
    XCTAssertEqual(url.host, "pair")
    XCTAssertEqual(decoded, invitation)
  }

  func testPairingInvitationCodecRejectsExpiredPayload() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let invitation = makeInvitation(
      now: now,
      expiresAt: now.addingTimeInterval(-1)
    )
    let url = try MobilePairingInvitationCodec.encode(invitation)

    XCTAssertThrowsError(try MobilePairingInvitationCodec.decode(url, now: now)) { error in
      XCTAssertEqual(error as? MobilePairingError, .expired(invitation.expiresAt))
    }
  }

  func testPairingServiceVerifiesStationFingerprintAndDerivesSharedKey() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let stationPrivateKey = Curve25519.KeyAgreement.PrivateKey()
    let invitation = makeInvitation(
      now: now,
      publicKeyFingerprint: MobileCryptoFingerprint.fingerprint(
        stationPrivateKey.publicKey.rawRepresentation
      )
    )
    let response = MobilePairingResponse(
      stationID: invitation.stationID,
      stationName: invitation.stationName,
      nonce: invitation.nonce,
      stationAgreementKeyRawRepresentation: stationPrivateKey.publicKey.rawRepresentation,
      snapshotKeyID: "snapshot-key",
      commandKeyID: "command-key",
      pairedAt: now
    )
    let transport = FakePairingTransport(response: response)
    let service = MobilePairingService(transport: transport)
    let identity = MobileDeviceIdentity(
      id: "device-phone",
      displayName: "Phone",
      createdAt: now
    )

    let credential = try await service.pair(
      invitation: invitation,
      deviceIdentity: identity,
      now: now
    )
    let capturedRequest = await transport.lastRequest()
    let request = try XCTUnwrap(capturedRequest)
    let expectedKey = try stationDerivedKey(
      stationPrivateKey: stationPrivateKey,
      request: request,
      stationID: invitation.stationID,
      nonce: invitation.nonce,
      snapshotKeyID: response.snapshotKeyID
    )

    XCTAssertEqual(request.stationID, invitation.stationID)
    XCTAssertEqual(request.nonce, invitation.nonce)
    XCTAssertEqual(request.deviceID, identity.id)
    XCTAssertEqual(credential.stationID, invitation.stationID)
    XCTAssertEqual(credential.commandKeyID, "command-key")
    XCTAssertEqual(credential.symmetricKeyRawRepresentation, expectedKey)
  }

  func testURLSessionPairingTransportWaitsForLocalNetworkConnectivity() {
    let configuration = URLSessionMobilePairingTransport.defaultSessionConfiguration()

    XCTAssertTrue(configuration.waitsForConnectivity)
    XCTAssertEqual(configuration.timeoutIntervalForRequest, 30)
    XCTAssertEqual(configuration.timeoutIntervalForResource, 60)
  }

  func testPairingCoordinatorCreatesDeviceIdentityAndPersistsCredential() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let stationPrivateKey = Curve25519.KeyAgreement.PrivateKey()
    let invitation = makeInvitation(
      now: now,
      publicKeyFingerprint: MobileCryptoFingerprint.fingerprint(
        stationPrivateKey.publicKey.rawRepresentation
      )
    )
    let response = MobilePairingResponse(
      stationID: invitation.stationID,
      stationName: invitation.stationName,
      nonce: invitation.nonce,
      stationAgreementKeyRawRepresentation: stationPrivateKey.publicKey.rawRepresentation,
      snapshotKeyID: "snapshot-key",
      commandKeyID: "command-key",
      pairedAt: now
    )
    let identityStore = InMemoryMobileDeviceIdentityStore()
    let credentialStore = InMemoryMobilePairedStationCredentialStore()
    let coordinator = MobilePairingCoordinator(
      identityStore: identityStore,
      credentialStore: credentialStore,
      transport: FakePairingTransport(response: response)
    )

    let credential = try await coordinator.pair(
      invitationURL: MobilePairingInvitationCodec.encode(invitation),
      deviceName: "Bart's iPhone",
      now: now
    )
    let storedIdentity = try await identityStore.load(
      id: MobilePairingCoordinator<FakePairingTransport>.defaultIdentityID
    )
    let storedCredential = try await credentialStore.load(stationID: invitation.stationID)

    XCTAssertEqual(storedIdentity?.displayName, "Bart's iPhone")
    XCTAssertEqual(storedCredential, credential)
    XCTAssertTrue(credential.defaultStation)
  }

  func testWatchPairingTransferRoundTripsStoredPairings() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let identity = MobileDeviceIdentity(
      id: "device-phone",
      displayName: "Bart's iPhone",
      signingPrivateKeyRawRepresentation: Data(repeating: 1, count: 32),
      agreementPrivateKeyRawRepresentation: Data(repeating: 2, count: 32),
      createdAt: now
    )
    let credential = MobilePairedStationCredential(
      stationID: "station-mac-studio",
      stationName: "Studio",
      endpoint: URL(string: "https://studio.local/pair")!,
      stationPublicKeyFingerprint: "00:11:22:33:44:55:66:77",
      deviceIdentityID: identity.id,
      snapshotKeyID: "snapshot-key",
      commandKeyID: "command-key",
      symmetricKeyRawRepresentation: Data(repeating: 3, count: 32),
      pairedAt: now,
      lastUsedAt: now.addingTimeInterval(10),
      defaultStation: true
    )
    let transfer = MobileWatchPairingTransfer(
      identities: [identity],
      credentials: [credential],
      snapshot: MobileMirrorSnapshot.empty(now: now),
      exportedAt: now.addingTimeInterval(20)
    )

    let decoded = try MobileWatchPairingTransfer.decode(try transfer.encodedData())

    XCTAssertEqual(decoded, transfer)
  }

  func testWatchPairingTransferDropsSnapshotWhenPayloadExceedsLimit() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let identity = makeIdentity(id: "device-phone", now: now)
    let credential = makeCredential(
      stationID: "station-mac-studio",
      deviceIdentityID: identity.id,
      now: now
    )
    let station = MobileStationSummary(
      id: credential.stationID,
      displayName: "Studio",
      state: .online,
      lastSeenAt: now,
      activeSessionCount: 1,
      needsYouCount: 0,
      commandQueueCount: 0,
      defaultStation: true
    )
    let snapshot = MobileMirrorSnapshot(
      revision: 42,
      generatedAt: now,
      expiresAt: now.addingTimeInterval(60),
      stations: [station],
      attention: [],
      sessions: [
        MobileSessionSummary(
          id: "session-large",
          stationID: credential.stationID,
          projectName: "Harness",
          title: "Large snapshot",
          branch: "main",
          status: "Active",
          activeAgentCount: 1,
          blockedAgentCount: 0,
          lastActivityAt: now,
          summary: String(repeating: "mirrored mobile state ", count: 5_000)
        )
      ],
      reviews: [],
      taskBoardItems: [],
      commands: [],
      trustedDevices: []
    )
    let transfer = MobileWatchPairingTransfer(
      identities: [identity],
      credentials: [credential],
      snapshot: snapshot,
      exportedAt: now.addingTimeInterval(20)
    )

    let decoded = try MobileWatchPairingTransfer.decode(
      try transfer.encodedData(maximumBytes: 1_024)
    )

    XCTAssertEqual(decoded.identities, [identity])
    XCTAssertEqual(decoded.credentials, [credential])
    XCTAssertNil(decoded.snapshot)
    XCTAssertEqual(decoded.exportedAt, transfer.exportedAt)
  }

  func testWatchPairingTransferPlansCredentialReplacementDeletesOnlyStaleIdentities() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let current = [
      makeCredential(
        stationID: "station-studio",
        deviceIdentityID: "device-phone",
        now: now
      ),
      makeCredential(
        stationID: "station-laptop",
        deviceIdentityID: "device-phone",
        now: now
      ),
      makeCredential(
        stationID: "station-old",
        deviceIdentityID: "device-old",
        now: now
      ),
    ]
    let transfer = MobileWatchPairingTransfer(
      identities: [
        makeIdentity(id: "device-phone", now: now)
      ],
      credentials: [
        makeCredential(
          stationID: "station-studio",
          deviceIdentityID: "device-phone",
          now: now
        )
      ],
      exportedAt: now.addingTimeInterval(20)
    )

    let plan = transfer.replacementPlan(replacing: current)

    XCTAssertEqual(
      plan.credentialStationIDsToDelete,
      ["station-laptop", "station-old"]
    )
    XCTAssertEqual(plan.identityIDsToDelete, ["device-old"])
  }

  func testPairedStationPlaceholdersInsertMissingStations() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let credential = makeCredential(
      stationID: "station-studio",
      deviceIdentityID: "device-phone",
      now: now
    )
    var snapshot = MobileMirrorSnapshot.empty(now: now)

    let changed = snapshot.ensurePairedStationPlaceholders(
      for: [credential],
      defaultStationID: credential.stationID,
      now: now
    )

    XCTAssertTrue(changed)
    XCTAssertEqual(snapshot.stations.count, 1)
    XCTAssertEqual(snapshot.stations.first?.id, credential.stationID)
    XCTAssertEqual(snapshot.stations.first?.displayName, credential.stationName)
    XCTAssertEqual(snapshot.stations.first?.state, .stale)
    XCTAssertEqual(snapshot.stations.first?.defaultStation, true)
  }

  func testPairedStationPlaceholdersNormalizeDefaultStation() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var snapshot = MobileMirrorSnapshot.empty(now: now)
    snapshot.stations = [
      MobileStationSummary(
        id: "station-studio",
        displayName: "Studio",
        state: .online,
        lastSeenAt: now,
        activeSessionCount: 1,
        needsYouCount: 0,
        commandQueueCount: 0,
        defaultStation: false
      ),
      MobileStationSummary(
        id: "station-laptop",
        displayName: "Laptop",
        state: .stale,
        lastSeenAt: now,
        activeSessionCount: 0,
        needsYouCount: 0,
        commandQueueCount: 0,
        defaultStation: true
      ),
    ]
    let credentials = [
      makeCredential(
        stationID: "station-studio",
        deviceIdentityID: "device-phone",
        now: now
      ),
      makeCredential(
        stationID: "station-laptop",
        deviceIdentityID: "device-phone",
        now: now
      ),
    ]

    let changed = snapshot.ensurePairedStationPlaceholders(
      for: credentials,
      defaultStationID: "station-studio",
      now: now
    )

    XCTAssertTrue(changed)
    XCTAssertEqual(snapshot.stations.first { $0.id == "station-studio" }?.defaultStation, true)
    XCTAssertEqual(snapshot.stations.first { $0.id == "station-laptop" }?.defaultStation, false)
  }

  func testStationAcceptorTrustsDeviceAndDerivesSharedKey() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let stationIdentity = MobilePairingStationIdentity(
      stationID: "station-mac-studio",
      stationName: "Studio",
      snapshotKeyID: "snapshot-key",
      commandKeyID: "command-key",
      createdAt: now
    )
    let trustStore = InMemoryMobilePairingTrustedDeviceStore()
    let acceptor = MobilePairingStationAcceptor(
      identity: stationIdentity,
      trustStore: trustStore
    )
    let deviceIdentity = MobileDeviceIdentity(
      id: "device-phone",
      displayName: "Bart's iPhone",
      createdAt: now
    )
    let request = try MobilePairingRequest(
      stationID: stationIdentity.stationID,
      nonce: "pairing-nonce",
      deviceID: deviceIdentity.id,
      deviceDisplayName: deviceIdentity.displayName,
      deviceSigningPublicKeyRawRepresentation: deviceIdentity.signingPublicKeyRawRepresentation(),
      deviceAgreementKeyRawRepresentation:
        deviceIdentity.agreementPublicKeyRawRepresentation(),
      deviceSigningKeyFingerprint: deviceIdentity.signingKeyFingerprint()
    )

    let response = try await acceptor.accept(
      request,
      expectedNonce: "pairing-nonce",
      now: now
    )
    let trustedDevice = try await trustStore.trustedDevice(
      deviceID: deviceIdentity.id,
      signingKeyFingerprint: try deviceIdentity.signingKeyFingerprint()
    )
    let expectedKey = try stationDerivedKey(
      stationPrivateKey: Curve25519.KeyAgreement.PrivateKey(
        rawRepresentation: stationIdentity.agreementPrivateKeyRawRepresentation
      ),
      request: request,
      stationID: stationIdentity.stationID,
      nonce: request.nonce,
      snapshotKeyID: stationIdentity.snapshotKeyID
    )

    XCTAssertEqual(response.stationID, stationIdentity.stationID)
    XCTAssertEqual(response.commandKeyID, stationIdentity.commandKeyID)
    XCTAssertEqual(trustedDevice?.deviceID, deviceIdentity.id)
    XCTAssertEqual(trustedDevice?.symmetricKeyRawRepresentation, expectedKey)
  }

  private func makeInvitation(
    now: Date,
    publicKeyFingerprint: String = "00:11:22:33:44:55:66:77",
    expiresAt: Date? = nil
  ) -> MobilePairingInvitation {
    MobilePairingInvitation(
      stationID: "station-mac-studio",
      stationName: "Studio",
      endpoint: URL(string: "http://studio.local:53741/pair")!,
      publicKeyFingerprint: publicKeyFingerprint,
      nonce: "pairing-nonce",
      expiresAt: expiresAt ?? now.addingTimeInterval(60)
    )
  }

  private func makeIdentity(id: String, now: Date) -> MobileDeviceIdentity {
    MobileDeviceIdentity(
      id: id,
      displayName: id,
      signingPrivateKeyRawRepresentation: Data(repeating: 1, count: 32),
      agreementPrivateKeyRawRepresentation: Data(repeating: 2, count: 32),
      createdAt: now
    )
  }

  private func makeCredential(
    stationID: String,
    deviceIdentityID: String,
    now: Date
  ) -> MobilePairedStationCredential {
    MobilePairedStationCredential(
      stationID: stationID,
      stationName: stationID,
      endpoint: URL(string: "https://\(stationID).local/pair")!,
      stationPublicKeyFingerprint: "00:11:22:33:44:55:66:77",
      deviceIdentityID: deviceIdentityID,
      snapshotKeyID: "snapshot-key",
      commandKeyID: "command-key",
      symmetricKeyRawRepresentation: Data(repeating: 3, count: 32),
      pairedAt: now,
      lastUsedAt: now.addingTimeInterval(10),
      defaultStation: stationID == "station-studio"
    )
  }

  private func stationDerivedKey(
    stationPrivateKey: Curve25519.KeyAgreement.PrivateKey,
    request: MobilePairingRequest,
    stationID: String,
    nonce: String,
    snapshotKeyID: String
  ) throws -> Data {
    let devicePublicKey = try Curve25519.KeyAgreement.PublicKey(
      rawRepresentation: request.deviceAgreementKeyRawRepresentation
    )
    let sharedSecret = try stationPrivateKey.sharedSecretFromKeyAgreement(with: devicePublicKey)
    let key = sharedSecret.hkdfDerivedSymmetricKey(
      using: SHA256.self,
      salt: Data(nonce.utf8),
      sharedInfo: Data("HarnessMonitorMobilePairing:\(stationID):\(snapshotKeyID)".utf8),
      outputByteCount: 32
    )
    return key.withUnsafeBytes { Data($0) }
  }
}

private actor FakePairingTransport: MobilePairingTransport {
  private let response: MobilePairingResponse
  private var capturedRequest: MobilePairingRequest?

  init(response: MobilePairingResponse) {
    self.response = response
  }

  func sendPairingRequest(
    _ request: MobilePairingRequest,
    to endpoint: URL
  ) async throws -> MobilePairingResponse {
    capturedRequest = request
    return response
  }

  func lastRequest() -> MobilePairingRequest? {
    capturedRequest
  }
}
