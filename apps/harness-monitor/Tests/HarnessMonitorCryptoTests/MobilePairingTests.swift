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
      stationAgreementPublicKeyRawRepresentation: stationPrivateKey.publicKey.rawRepresentation,
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
      stationAgreementPublicKeyRawRepresentation: stationPrivateKey.publicKey.rawRepresentation,
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

  private func stationDerivedKey(
    stationPrivateKey: Curve25519.KeyAgreement.PrivateKey,
    request: MobilePairingRequest,
    stationID: String,
    nonce: String,
    snapshotKeyID: String
  ) throws -> Data {
    let devicePublicKey = try Curve25519.KeyAgreement.PublicKey(
      rawRepresentation: request.deviceAgreementPublicKeyRawRepresentation
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
