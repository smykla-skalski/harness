import CryptoKit
import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto
import XCTest

final class MobilePairingStationTests: XCTestCase {
  func testPairedStationPlaceholdersInsertMissingStations() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let credential = makePairedStationCredential(
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
    let expectedKey = try stationDerivedSharedKey(
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
}
