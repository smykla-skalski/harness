import CryptoKit
import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto
import XCTest

final class MobileCryptoTests: XCTestCase {
  func testCommandSignatureVerifiesAndRejectsTampering() throws {
    let identity = MobileDeviceIdentity(displayName: "Phone")
    let command = makeCommand()

    let signed = try MobileCommandSigner.sign(command: command, identity: identity)

    XCTAssertTrue(
      try MobileCommandSigner.verify(
        signed,
        publicKeyRawRepresentation: identity.signingPublicKeyRawRepresentation()
      )
    )

    var tampered = signed
    tampered.command.title = "Different command"
    XCTAssertFalse(
      try MobileCommandSigner.verify(
        tampered,
        publicKeyRawRepresentation: identity.signingPublicKeyRawRepresentation()
      )
    )
  }

  func testEncryptedEnvelopeRoundTripsOpaquePayload() throws {
    let key = SymmetricKey(size: .bits256)
    let command = makeCommand()

    let envelope = try MobileEncryptedPayloadCodec.seal(
      command,
      keyID: "station-key",
      symmetricKey: key,
      additionalAuthenticatedData: Data("station".utf8)
    )
    let decoded: MobileCommandRecord = try MobileEncryptedPayloadCodec.open(
      envelope,
      symmetricKey: key
    )

    XCTAssertEqual(decoded, command)
    XCTAssertFalse(envelope.ciphertext.isEmpty)
  }

  func testReplayProtectorAcceptsCommandOnce() async throws {
    let identity = MobileDeviceIdentity(displayName: "Phone")
    let signed = try MobileCommandSigner.sign(command: makeCommand(), identity: identity)
    let replayProtector = MobileReplayProtector()
    let now = Date(timeIntervalSince1970: 1_700_000_001)

    let firstAccept = await replayProtector.accept(signed, now: now)
    let secondAccept = await replayProtector.accept(signed, now: now)

    XCTAssertTrue(firstAccept)
    XCTAssertFalse(secondAccept)
  }

  func testIdentityStorePersistsDeviceKeysWithoutChangingFingerprints() async throws {
    let identity = MobileDeviceIdentity(displayName: "Phone")
    let store = InMemoryMobileDeviceIdentityStore()

    try await store.save(identity)
    let loaded = try await store.load(id: identity.id)

    XCTAssertEqual(loaded, identity)
    XCTAssertEqual(try loaded?.signingKeyFingerprint(), try identity.signingKeyFingerprint())

    try await store.delete(id: identity.id)
    let deleted = try await store.load(id: identity.id)
    XCTAssertNil(deleted)
  }

  private func makeCommand() -> MobileCommandRecord {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    return MobileCommandRecord(
      id: "command",
      stationID: "station",
      kind: .refresh,
      risk: .low,
      status: .queued,
      title: "Refresh",
      confirmationText: "Refresh station",
      target: MobileCommandTarget(stationID: "station", targetRevision: 2),
      actorDeviceID: "phone",
      createdAt: now,
      expiresAt: now.addingTimeInterval(60),
      updatedAt: now
    )
  }
}
