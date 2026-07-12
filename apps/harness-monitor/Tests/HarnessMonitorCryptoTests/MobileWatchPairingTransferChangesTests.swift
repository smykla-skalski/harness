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

  func testPhoneTransferPreservesDirectWatchCredentialForSameStation() throws {
    let phoneIdentity = makePairingIdentity(id: "default-mobile-device", now: now)
    let watchIdentity = makePairingIdentity(
      id: MobileRemoteDaemonPairingDevice.watchOS.identityID,
      now: now
    )
    let phoneCredential = try makeRemoteCredential(
      identityID: phoneIdentity.id,
      platform: "ios",
      token: "phone-token"
    )
    let watchCredential = try makeRemoteCredential(
      identityID: watchIdentity.id,
      platform: "watchos",
      token: "watch-token"
    )
    let transfer = MobileWatchPairingTransfer(
      identities: [phoneIdentity],
      credentials: [phoneCredential],
      snapshot: .empty(),
      exportedAt: now
    )

    let reconciled = transfer.preservingLocallyPairedRemoteCredentials(
      for: .watchOS,
      currentIdentities: [watchIdentity],
      currentCredentials: [watchCredential]
    )

    XCTAssertEqual(reconciled.credentials, [watchCredential])
    XCTAssertEqual(reconciled.identities, [watchIdentity])
    XCTAssertEqual(reconciled.snapshot, transfer.snapshot)
    XCTAssertFalse(
      reconciled.changesPairingMaterial(
        currentIdentities: [watchIdentity],
        currentCredentials: [watchCredential]
      )
    )
  }

  func testEmptyPhoneTransferPreservesDirectWatchCredential() throws {
    let watchIdentity = makePairingIdentity(
      id: MobileRemoteDaemonPairingDevice.watchOS.identityID,
      now: now
    )
    let watchCredential = try makeRemoteCredential(
      identityID: watchIdentity.id,
      platform: "watchos",
      token: "watch-token"
    )
    let transfer = MobileWatchPairingTransfer(
      identities: [],
      credentials: [],
      snapshot: .empty(),
      exportedAt: now
    )

    let reconciled = transfer.preservingLocallyPairedRemoteCredentials(
      for: .watchOS,
      currentIdentities: [watchIdentity],
      currentCredentials: [watchCredential]
    )

    XCTAssertEqual(reconciled.credentials, [watchCredential])
    XCTAssertEqual(reconciled.identities, [watchIdentity])
    XCTAssertEqual(reconciled.snapshot, transfer.snapshot)
  }

  func testEmptyPhoneTransferRemovesAllTransferredCredentials() {
    let phoneIdentity = makePairingIdentity(id: "default-mobile-device", now: now)
    let phoneCredential = makePairedStationCredential(
      stationID: "relay-stale",
      deviceIdentityID: phoneIdentity.id,
      now: now
    )
    let transfer = MobileWatchPairingTransfer(
      identities: [],
      credentials: [],
      exportedAt: now
    )

    let plan = transfer.replacementPlan(replacing: [phoneCredential])

    XCTAssertEqual(plan.credentialStationIDsToDelete, [phoneCredential.stationID])
    XCTAssertEqual(plan.identityIDsToDelete, [phoneIdentity.id])
  }

  func testEmptyPhoneTransferBuildsWatchConnectivityPayload() throws {
    let transfer = MobileWatchPairingTransfer(
      identities: [],
      credentials: [],
      exportedAt: now
    )

    let payload = try transfer.watchConnectivityPayload(maximumBytes: 60 * 1024)
    let data = try XCTUnwrap(
      payload[MobileWatchPairingTransferEnvelope.transferKey] as? Data
    )

    XCTAssertEqual(try MobileWatchPairingTransfer.decode(data), transfer)
  }

  func testEmptyPhoneTransferPreservesWatchOwnedCredentialWhileRemovingPhoneCredential() throws {
    let phoneIdentity = makePairingIdentity(id: "default-mobile-device", now: now)
    let watchIdentity = makePairingIdentity(
      id: MobileRemoteDaemonPairingDevice.watchOS.identityID,
      now: now
    )
    let phoneCredential = makePairedStationCredential(
      stationID: "relay-stale",
      deviceIdentityID: phoneIdentity.id,
      now: now
    )
    let watchCredential = try makeRemoteCredential(
      stationID: "remote-watch",
      identityID: watchIdentity.id,
      platform: "watchos",
      token: "watch-token"
    )
    let transfer = MobileWatchPairingTransfer(
      identities: [],
      credentials: [],
      exportedAt: now
    )

    let reconciled = transfer.preservingLocallyPairedRemoteCredentials(
      for: .watchOS,
      currentIdentities: [phoneIdentity, watchIdentity],
      currentCredentials: [phoneCredential, watchCredential]
    )
    let plan = reconciled.replacementPlan(
      replacing: [phoneCredential, watchCredential]
    )

    XCTAssertEqual(reconciled.credentials, [watchCredential])
    XCTAssertEqual(reconciled.identities, [watchIdentity])
    XCTAssertEqual(plan.credentialStationIDsToDelete, [phoneCredential.stationID])
    XCTAssertEqual(plan.identityIDsToDelete, [phoneIdentity.id])
  }

  func testPhoneTransferStillReplacesStaleTransferredCredentials() throws {
    let phoneIdentity = makePairingIdentity(id: "default-mobile-device", now: now)
    let watchIdentity = makePairingIdentity(
      id: MobileRemoteDaemonPairingDevice.watchOS.identityID,
      now: now
    )
    let watchCredential = try makeRemoteCredential(
      stationID: "remote-watch",
      identityID: watchIdentity.id,
      platform: "watchos",
      token: "watch-token"
    )
    let stalePhoneCredential = makePairedStationCredential(
      stationID: "relay-stale",
      deviceIdentityID: phoneIdentity.id,
      now: now
    )
    let replacementPhoneCredential = makePairedStationCredential(
      stationID: "relay-current",
      deviceIdentityID: phoneIdentity.id,
      now: now
    )
    let transfer = MobileWatchPairingTransfer(
      identities: [phoneIdentity],
      credentials: [replacementPhoneCredential],
      exportedAt: now
    )

    let reconciled = transfer.preservingLocallyPairedRemoteCredentials(
      for: .watchOS,
      currentIdentities: [phoneIdentity, watchIdentity],
      currentCredentials: [watchCredential, stalePhoneCredential]
    )
    let plan = reconciled.replacementPlan(
      replacing: [watchCredential, stalePhoneCredential]
    )

    XCTAssertEqual(
      Set(reconciled.credentials.map(\.stationID)),
      Set(["remote-watch", "relay-current"])
    )
    XCTAssertEqual(Set(reconciled.identities.map(\.id)), Set([phoneIdentity.id, watchIdentity.id]))
    XCTAssertEqual(plan.credentialStationIDsToDelete, ["relay-stale"])
    XCTAssertFalse(plan.credentialStationIDsToDelete.contains(watchCredential.stationID))
  }

  func testDuplicateIncomingIdentityIDsUseTheLastValue() throws {
    let firstPhoneIdentity = makePairingIdentity(id: "default-mobile-device", now: now)
    var latestPhoneIdentity = firstPhoneIdentity
    latestPhoneIdentity.displayName = "Latest iPhone"
    let watchIdentity = makePairingIdentity(
      id: MobileRemoteDaemonPairingDevice.watchOS.identityID,
      now: now
    )
    let phoneCredential = makePairedStationCredential(
      stationID: "relay-phone",
      deviceIdentityID: firstPhoneIdentity.id,
      now: now
    )
    let watchCredential = try makeRemoteCredential(
      stationID: "remote-watch",
      identityID: watchIdentity.id,
      platform: "watchos",
      token: "watch-token"
    )
    let transfer = MobileWatchPairingTransfer(
      identities: [firstPhoneIdentity, latestPhoneIdentity],
      credentials: [phoneCredential],
      exportedAt: now
    )

    let reconciled = transfer.preservingLocallyPairedRemoteCredentials(
      for: .watchOS,
      currentIdentities: [watchIdentity],
      currentCredentials: [watchCredential]
    )

    XCTAssertEqual(
      reconciled.identities.first(where: { $0.id == latestPhoneIdentity.id }),
      latestPhoneIdentity
    )
  }

  func testDuplicateIncomingStationsUseTheLastCredential() throws {
    let firstPhoneIdentity = makePairingIdentity(id: "phone-first", now: now)
    let latestPhoneIdentity = makePairingIdentity(id: "phone-latest", now: now)
    let watchIdentity = makePairingIdentity(
      id: MobileRemoteDaemonPairingDevice.watchOS.identityID,
      now: now
    )
    let firstPhoneCredential = makePairedStationCredential(
      stationID: "relay-phone",
      deviceIdentityID: firstPhoneIdentity.id,
      now: now
    )
    let latestPhoneCredential = makePairedStationCredential(
      stationID: "relay-phone",
      deviceIdentityID: latestPhoneIdentity.id,
      now: now
    )
    let watchCredential = try makeRemoteCredential(
      stationID: "remote-watch",
      identityID: watchIdentity.id,
      platform: "watchos",
      token: "watch-token"
    )
    let transfer = MobileWatchPairingTransfer(
      identities: [firstPhoneIdentity, latestPhoneIdentity],
      credentials: [firstPhoneCredential, latestPhoneCredential],
      exportedAt: now
    )

    let reconciled = transfer.preservingLocallyPairedRemoteCredentials(
      for: .watchOS,
      currentIdentities: [watchIdentity],
      currentCredentials: [watchCredential]
    )

    XCTAssertEqual(
      reconciled.credentials.filter { $0.stationID == latestPhoneCredential.stationID },
      [latestPhoneCredential]
    )
    XCTAssertEqual(
      Set(reconciled.identities.map(\.id)),
      Set([latestPhoneIdentity.id, watchIdentity.id])
    )
  }
}

private func makeRemoteCredential(
  stationID: String = "remote-daemon-example-com",
  identityID: String,
  platform: String,
  token: String
) throws -> MobilePairedStationCredential {
  let endpoint = URL(string: "https://daemon.example.com")!
  let pin = try MobileRemoteDaemonSPKIPin(
    validating: "sha256/CQ8Rnn313xPUG+5zny4xTooD6AxAsZr/anC/ea4bTIY="
  )
  return MobilePairedStationCredential(
    stationID: stationID,
    stationName: "daemon.example.com",
    endpoint: endpoint,
    stationPublicKeyFingerprint: pin.value,
    deviceIdentityID: identityID,
    snapshotKeyID: "",
    commandKeyID: "",
    symmetricKeyRawRepresentation: Data(),
    pairedAt: Date(timeIntervalSince1970: 1_700_000_000),
    defaultStation: true,
    remoteDaemonAccess: MobileRemoteDaemonAccess(
      endpoint: endpoint,
      clientID: "\(platform)-client",
      displayName: platform,
      platform: platform,
      role: .operator,
      scopes: ["read", "write"],
      bearerToken: token,
      tokenHint: String(token.suffix(4)),
      serverSPKISHA256: pin,
      pairedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  )
}
