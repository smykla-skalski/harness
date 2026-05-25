import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import XCTest

final class MobileCloudMirrorBackgroundRefreshTests: XCTestCase {
  func testRefreshFetchesPairedStationSnapshotIntoSharedStore() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let identity = MobileDeviceIdentity(id: "device-phone", displayName: "Phone")
    let credential = makeCredential(deviceIdentityID: identity.id, now: now)
    let database = InMemoryMobileCloudMirrorDatabase()
    let sharedStore = InMemorySharedMirrorSnapshotStore()
    let expectedSnapshot = MobileDemoFixtures.snapshot(now: now)
    try await saveSnapshot(expectedSnapshot, credential: credential, database: database, now: now)
    let refresher = MobileCloudMirrorBackgroundRefresher(
      identityStore: InMemoryMobileDeviceIdentityStore(identities: [identity]),
      credentialStore: InMemoryMobilePairedStationCredentialStore(credentials: [credential]),
      sharedSnapshotStore: sharedStore,
      databaseFactory: { database }
    )

    let result = await refresher.refresh(now: now)

    XCTAssertTrue(result.didRefresh)
    XCTAssertEqual(result.refreshedStationIDs, [credential.stationID])
    XCTAssertEqual(result.failedStationIDs, [])
    XCTAssertEqual(
      result.snapshot?.station(id: credential.stationID)?.displayName,
      expectedSnapshot.station(id: credential.stationID)?.displayName
    )
    let storedSnapshot = try XCTUnwrap(sharedStore.loadLatestSnapshot())
    XCTAssertEqual(storedSnapshot.needsYouCount, expectedSnapshot.needsYouCount)
  }

  func testRefreshKeepsCachedSnapshotWhenIdentityIsMissing() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let credential = makeCredential(deviceIdentityID: "missing-device", now: now)
    let cachedSnapshot = MobileDemoFixtures.snapshot(now: now)
    let sharedStore = InMemorySharedMirrorSnapshotStore(snapshot: cachedSnapshot)
    let refresher = MobileCloudMirrorBackgroundRefresher(
      identityStore: InMemoryMobileDeviceIdentityStore(),
      credentialStore: InMemoryMobilePairedStationCredentialStore(credentials: [credential]),
      sharedSnapshotStore: sharedStore,
      databaseFactory: { InMemoryMobileCloudMirrorDatabase() }
    )

    let result = await refresher.refresh(now: now)

    XCTAssertFalse(result.didRefresh)
    XCTAssertEqual(result.failedStationIDs, [credential.stationID])
    XCTAssertEqual(result.snapshot, cachedSnapshot)
    XCTAssertEqual(try sharedStore.loadLatestSnapshot(), cachedSnapshot)
  }

  private func makeCredential(deviceIdentityID: String, now: Date) -> MobilePairedStationCredential {
    MobilePairedStationCredential(
      stationID: "station-mac-studio",
      stationName: "Studio",
      endpoint: URL(string: "https://studio.local/pair")!,
      stationPublicKeyFingerprint: "AA:BB:CC:DD:EE:FF:00:11",
      deviceIdentityID: deviceIdentityID,
      snapshotKeyID: "snapshot-key",
      commandKeyID: "command-key",
      symmetricKeyRawRepresentation: Data(repeating: 7, count: 32),
      pairedAt: now,
      defaultStation: true
    )
  }

  private func saveSnapshot(
    _ snapshot: MobileMirrorSnapshot,
    credential: MobilePairedStationCredential,
    database: InMemoryMobileCloudMirrorDatabase,
    now: Date
  ) async throws {
    let cipher = MobilePayloadCipher(rawKey: credential.symmetricKeyRawRepresentation)
    let metadata = MobileMirrorRecordMetadata(
      id: "snapshot-\(credential.stationID)",
      type: .snapshot,
      stationID: credential.stationID,
      revision: snapshot.revision,
      updatedAt: now,
      expiresAt: now.addingTimeInterval(60)
    )
    let envelope = try cipher.seal(
      snapshot,
      keyID: credential.snapshotKeyID,
      additionalAuthenticatedData: MobileCloudMirrorRecordAAD.data(for: metadata),
      createdAt: now
    )
    try await database.save(MobileMirrorRecord(metadata: metadata, envelope: envelope))
  }
}

private final class InMemorySharedMirrorSnapshotStore:
  MobileSharedMirrorSnapshotPersisting,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var snapshot: MobileMirrorSnapshot?

  init(snapshot: MobileMirrorSnapshot? = nil) {
    self.snapshot = snapshot
  }

  func loadLatestSnapshot() throws -> MobileMirrorSnapshot? {
    lock.lock()
    defer { lock.unlock() }
    return snapshot
  }

  func save(_ snapshot: MobileMirrorSnapshot, savedAt: Date) throws {
    lock.lock()
    defer { lock.unlock() }
    self.snapshot = snapshot
  }
}
