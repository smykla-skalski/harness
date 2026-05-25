import CryptoKit
import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto
import XCTest

final class MobilePairingTests: XCTestCase {
  func testPairingInvitationCodecRoundTripsURLPayload() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let invitation = makePairingInvitation(now: now)

    let url = try MobilePairingInvitationCodec.encode(invitation)
    let decoded = try MobilePairingInvitationCodec.decode(url, now: now)

    XCTAssertEqual(url.scheme, "harness")
    XCTAssertEqual(url.host, "pair")
    XCTAssertEqual(decoded, invitation)
  }

  func testPairingInvitationCodecRejectsExpiredPayload() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let invitation = makePairingInvitation(
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
    let invitation = makePairingInvitation(
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
    let expectedKey = try stationDerivedSharedKey(
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
    let invitation = makePairingInvitation(
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
    let identity = makePairingIdentity(id: "device-phone", now: now)
    let credential = makePairedStationCredential(
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

    let encoded = try transfer.encodedData(maximumBytes: 1_024)
    let decoded = try MobileWatchPairingTransfer.decode(encoded)

    XCTAssertLessThanOrEqual(encoded.count, 1_024)
    XCTAssertEqual(decoded.identities, [identity])
    XCTAssertEqual(decoded.credentials, [credential])
    XCTAssertNil(decoded.snapshot)
    XCTAssertEqual(decoded.exportedAt, transfer.exportedAt)
  }

  func testWatchPairingTransferPlansCredentialReplacementDeletesOnlyStaleIdentities() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let current = [
      makePairedStationCredential(
        stationID: "station-studio",
        deviceIdentityID: "device-phone",
        now: now
      ),
      makePairedStationCredential(
        stationID: "station-laptop",
        deviceIdentityID: "device-phone",
        now: now
      ),
      makePairedStationCredential(
        stationID: "station-old",
        deviceIdentityID: "device-old",
        now: now
      ),
    ]
    let transfer = MobileWatchPairingTransfer(
      identities: [
        makePairingIdentity(id: "device-phone", now: now)
      ],
      credentials: [
        makePairedStationCredential(
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

  func testWatchPairingTransferDoesNotDeleteCredentialsForEmptyTransfer() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let current = [
      makePairedStationCredential(
        stationID: "station-studio",
        deviceIdentityID: "device-phone",
        now: now
      ),
      makePairedStationCredential(
        stationID: "station-laptop",
        deviceIdentityID: "device-phone",
        now: now
      ),
    ]
    let transfer = MobileWatchPairingTransfer(
      identities: [],
      credentials: [],
      exportedAt: now.addingTimeInterval(20)
    )

    let plan = transfer.replacementPlan(replacing: current)

    XCTAssertEqual(plan.credentialStationIDsToDelete, [])
    XCTAssertEqual(plan.identityIDsToDelete, [])
  }
}
