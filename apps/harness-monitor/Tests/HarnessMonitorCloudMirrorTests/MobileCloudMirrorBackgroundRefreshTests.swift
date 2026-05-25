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
    XCTAssertNil(result.previousSnapshot)
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
    XCTAssertEqual(result.previousSnapshot, cachedSnapshot)
    XCTAssertEqual(result.failedStationIDs, [credential.stationID])
    XCTAssertEqual(result.snapshot, cachedSnapshot)
    XCTAssertEqual(try sharedStore.loadLatestSnapshot(), cachedSnapshot)
  }

  func testRefreshMarksHangingFetchFailedWithoutReplacingCache() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let identity = MobileDeviceIdentity(id: "device-phone", displayName: "Phone")
    let credential = makeCredential(deviceIdentityID: identity.id, now: now)
    let cachedSnapshot = MobileDemoFixtures.snapshot(now: now)
    let sharedStore = InMemorySharedMirrorSnapshotStore(snapshot: cachedSnapshot)
    let database = HangingMobileCloudMirrorDatabase()
    let refresher = MobileCloudMirrorBackgroundRefresher(
      identityStore: InMemoryMobileDeviceIdentityStore(identities: [identity]),
      credentialStore: InMemoryMobilePairedStationCredentialStore(credentials: [credential]),
      sharedSnapshotStore: sharedStore,
      databaseFactory: { database },
      fetchTimeout: .milliseconds(20)
    )

    let result = await refresher.refresh(now: now)

    XCTAssertFalse(result.didRefresh)
    XCTAssertEqual(result.previousSnapshot, cachedSnapshot)
    XCTAssertEqual(result.refreshedStationIDs, [])
    XCTAssertEqual(result.failedStationIDs, [credential.stationID])
    XCTAssertEqual(result.snapshot, cachedSnapshot)
    XCTAssertEqual(try sharedStore.loadLatestSnapshot(), cachedSnapshot)
  }

  func testRefreshCarriesPreviousSnapshotForBackgroundNotifications() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let identity = MobileDeviceIdentity(id: "device-phone", displayName: "Phone")
    let credential = makeCredential(deviceIdentityID: identity.id, now: now)
    let database = InMemoryMobileCloudMirrorDatabase()
    let previousSnapshot = MobileMirrorSnapshot.empty(now: now.addingTimeInterval(-60))
    let sharedStore = InMemorySharedMirrorSnapshotStore(snapshot: previousSnapshot)
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
    XCTAssertEqual(result.previousSnapshot, previousSnapshot)
    XCTAssertEqual(result.snapshot?.needsYouCount, expectedSnapshot.needsYouCount)
  }

  func testRefreshPersistsPairedPlaceholderWhenSnapshotIsMissing() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let identity = MobileDeviceIdentity(id: "device-phone", displayName: "Phone")
    let credential = makeCredential(deviceIdentityID: identity.id, now: now)
    let sharedStore = InMemorySharedMirrorSnapshotStore()
    let refresher = MobileCloudMirrorBackgroundRefresher(
      identityStore: InMemoryMobileDeviceIdentityStore(identities: [identity]),
      credentialStore: InMemoryMobilePairedStationCredentialStore(credentials: [credential]),
      sharedSnapshotStore: sharedStore,
      databaseFactory: { InMemoryMobileCloudMirrorDatabase() }
    )

    let result = await refresher.refresh(now: now)

    XCTAssertFalse(result.didRefresh)
    XCTAssertNil(result.previousSnapshot)
    XCTAssertEqual(result.failedStationIDs, [credential.stationID])
    XCTAssertEqual(result.snapshot?.station(id: credential.stationID)?.displayName, "Studio")
    XCTAssertEqual(result.snapshot?.station(id: credential.stationID)?.state, .stale)
    let storedSnapshot = try XCTUnwrap(sharedStore.loadLatestSnapshot())
    XCTAssertEqual(storedSnapshot.station(id: credential.stationID)?.displayName, "Studio")
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

private actor HangingMobileCloudMirrorDatabase: MobileCloudMirrorDatabase {
  func save(_ record: MobileMirrorRecord) async throws {}

  func fetch(recordID: String) async throws -> MobileMirrorRecord? {
    nil
  }

  func fetchAll(stationID: String) async throws -> [MobileMirrorRecord] {
    await withUnsafeContinuation { (_: UnsafeContinuation<[MobileMirrorRecord], Never>) in }
  }

  func delete(recordID: String) async throws {}

  func ensureSubscription() async throws {}
}
