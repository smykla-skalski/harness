import Foundation
import HarnessMonitorCrypto
import XCTest

final class MobileWatchPairingTransferChangesTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  func testSameMaterialIsNotAChangeEvenWhenSnapshotDiffers() {
    let identity = makePairingIdentity(id: "device-watch", now: now)
    let credential = makePairedStationCredential(
      stationID: "station-studio",
      deviceIdentityID: identity.id,
      now: now
    )
    let transfer = MobileWatchPairingTransfer(
      identities: [identity],
      credentials: [credential],
      snapshot: .empty(),
      exportedAt: now.addingTimeInterval(120)
    )

    let changed = transfer.changesPairingMaterial(
      currentIdentities: [identity],
      currentCredentials: [credential]
    )

    XCTAssertFalse(changed, "a snapshot-only piggyback must not count as a pairing change")
  }

  func testReorderedMaterialIsNotAChange() {
    let identityA = makePairingIdentity(id: "device-a", now: now)
    let identityB = makePairingIdentity(id: "device-b", now: now)
    let credentialA = makePairedStationCredential(
      stationID: "station-a",
      deviceIdentityID: identityA.id,
      now: now
    )
    let credentialB = makePairedStationCredential(
      stationID: "station-b",
      deviceIdentityID: identityB.id,
      now: now
    )
    let transfer = MobileWatchPairingTransfer(
      identities: [identityB, identityA],
      credentials: [credentialB, credentialA],
      exportedAt: now
    )

    let changed = transfer.changesPairingMaterial(
      currentIdentities: [identityA, identityB],
      currentCredentials: [credentialA, credentialB]
    )

    XCTAssertFalse(changed, "order must not matter")
  }

  func testAddedCredentialIsAChange() {
    let identity = makePairingIdentity(id: "device-watch", now: now)
    let existing = makePairedStationCredential(
      stationID: "station-studio",
      deviceIdentityID: identity.id,
      now: now
    )
    let added = makePairedStationCredential(
      stationID: "station-laptop",
      deviceIdentityID: identity.id,
      now: now
    )
    let transfer = MobileWatchPairingTransfer(
      identities: [identity],
      credentials: [existing, added],
      exportedAt: now
    )

    let changed = transfer.changesPairingMaterial(
      currentIdentities: [identity],
      currentCredentials: [existing]
    )

    XCTAssertTrue(changed, "a newly paired station must trigger a reload")
  }

  func testRemovedCredentialIsAChange() {
    let identity = makePairingIdentity(id: "device-watch", now: now)
    let kept = makePairedStationCredential(
      stationID: "station-studio",
      deviceIdentityID: identity.id,
      now: now
    )
    let dropped = makePairedStationCredential(
      stationID: "station-laptop",
      deviceIdentityID: identity.id,
      now: now
    )
    let transfer = MobileWatchPairingTransfer(
      identities: [identity],
      credentials: [kept],
      exportedAt: now
    )

    let changed = transfer.changesPairingMaterial(
      currentIdentities: [identity],
      currentCredentials: [kept, dropped]
    )

    XCTAssertTrue(changed, "an unpaired station must trigger a reload")
  }

  func testRotatedCredentialKeyIsAChange() {
    let identity = makePairingIdentity(id: "device-watch", now: now)
    var current = makePairedStationCredential(
      stationID: "station-studio",
      deviceIdentityID: identity.id,
      now: now
    )
    current.symmetricKeyRawRepresentation = Data(repeating: 9, count: 32)
    let incoming = makePairedStationCredential(
      stationID: "station-studio",
      deviceIdentityID: identity.id,
      now: now
    )
    let transfer = MobileWatchPairingTransfer(
      identities: [identity],
      credentials: [incoming],
      exportedAt: now
    )

    let changed = transfer.changesPairingMaterial(
      currentIdentities: [identity],
      currentCredentials: [current]
    )

    XCTAssertTrue(changed, "a rotated symmetric key must trigger a reload")
  }

  func testRotatedIdentityKeyIsAChange() {
    var current = makePairingIdentity(id: "device-watch", now: now)
    current.signingPrivateKeyRawRepresentation = Data(repeating: 7, count: 32)
    let incoming = makePairingIdentity(id: "device-watch", now: now)
    let credential = makePairedStationCredential(
      stationID: "station-studio",
      deviceIdentityID: incoming.id,
      now: now
    )
    let transfer = MobileWatchPairingTransfer(
      identities: [incoming],
      credentials: [credential],
      exportedAt: now
    )

    let changed = transfer.changesPairingMaterial(
      currentIdentities: [current],
      currentCredentials: [credential]
    )

    XCTAssertTrue(changed, "a rotated identity key must trigger a reload")
  }
}
