import CloudKit
import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import XCTest

final class MobileCloudMirrorSnapshotWriterTests: XCTestCase {
  func testSnapshotWriterEncryptsOneOpaqueRecordPerTrustedDevice() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase()
    let writer = MobileCloudMirrorSnapshotWriter(database: database)
    let device = MobilePairingTrustedDevice(
      stationID: "station-mac-studio",
      deviceID: "device-phone",
      displayName: "Phone",
      signingKeyFingerprint: "AA:BB:CC:DD",
      signingPublicKeyRawRepresentation: Data([1]),
      agreementPublicKeyRawRepresentation: Data([2]),
      snapshotKeyID: "snapshot-key",
      commandKeyID: "command-key",
      symmetricKeyRawRepresentation: Data(repeating: 12, count: 32),
      pairedAt: now
    )
    let snapshot = MobileDemoFixtures.snapshot(now: now)

    let records = try await writer.writeSnapshot(
      snapshot,
      stationID: "station-mac-studio",
      devices: [device],
      now: now
    )
    let record = try XCTUnwrap(records.first)
    let fetched = try await database.fetch(recordID: record.id)
    let opened: MobileMirrorSnapshot = try MobilePayloadCipher(
      rawKey: device.symmetricKeyRawRepresentation
    )
    .open(try XCTUnwrap(fetched?.envelope))

    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(opened, snapshot)
    XCTAssertEqual(record.metadata.type, .snapshot)
    XCTAssertFalse(record.id.contains(device.deviceID))
    XCTAssertNil(String(data: record.envelope?.ciphertext ?? Data(), encoding: .utf8))
  }

  func testSnapshotWriterDeduplicatesRepeatedTrustedDevices() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase()
    let writer = MobileCloudMirrorSnapshotWriter(database: database)
    let device = MobilePairingTrustedDevice(
      stationID: "station-mac-studio",
      deviceID: "device-phone",
      displayName: "Phone",
      signingKeyFingerprint: "AA:BB:CC:DD",
      signingPublicKeyRawRepresentation: Data([1]),
      agreementPublicKeyRawRepresentation: Data([2]),
      snapshotKeyID: "snapshot-key",
      commandKeyID: "command-key",
      symmetricKeyRawRepresentation: Data(repeating: 12, count: 32),
      pairedAt: now
    )
    let snapshot = MobileDemoFixtures.snapshot(now: now)

    let records = try await writer.writeSnapshot(
      snapshot,
      stationID: "station-mac-studio",
      devices: [device, device],
      now: now
    )

    XCTAssertEqual(records.count, 1)
    let storedRecord = try await database.fetch(recordID: records[0].id)
    XCTAssertEqual(storedRecord, records[0])
  }

  func testSnapshotWriterChunksOversizedSnapshotAndSyncClientReassembles() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase()
    let writer = MobileCloudMirrorSnapshotWriter(
      database: database,
      snapshotCiphertextChunkSize: 512
    )
    let symmetricKey = Data(repeating: 13, count: 32)
    let device = MobilePairingTrustedDevice(
      stationID: "station-mac-studio",
      deviceID: "device-phone",
      displayName: "Phone",
      signingKeyFingerprint: "AA:BB:CC:DD",
      signingPublicKeyRawRepresentation: Data([1]),
      agreementPublicKeyRawRepresentation: Data([2]),
      snapshotKeyID: "snapshot-key",
      commandKeyID: "command-key",
      symmetricKeyRawRepresentation: symmetricKey,
      pairedAt: now
    )
    var snapshot = MobileDemoFixtures.snapshot(now: now)
    snapshot.revision = 99
    snapshot.taskBoardItems.append(
      MobileTaskBoardSummary(
        id: "task-large",
        stationID: "station-mac-studio",
        title: "Large mirrored task",
        bodyPreview: String(repeating: "review the mirrored payload ", count: 300),
        status: "plan_review",
        statusTitle: "Plan Review",
        priority: "high",
        priorityTitle: "High",
        agentMode: "planning",
        needsYou: true,
        updatedAt: now
      )
    )

    let records = try await writer.writeSnapshot(
      snapshot,
      stationID: "station-mac-studio",
      devices: [device],
      now: now
    )
    let parent = try XCTUnwrap(records.first { $0.metadata.type == .snapshot })
    let chunkRecords = records.filter { $0.metadata.type == .snapshotChunk }
    let client = MobileCloudMirrorSyncClient(
      database: database,
      cipher: MobilePayloadCipher(rawKey: symmetricKey),
      deviceIdentity: MobileDeviceIdentity(id: "device-phone", displayName: "Phone"),
      commandKeyID: "command-key"
    )

    XCTAssertFalse(parent.metadata.chunkIDs.isEmpty)
    XCTAssertEqual(parent.envelope?.ciphertext.count, 1)
    XCTAssertEqual(chunkRecords.map(\.id), parent.metadata.chunkIDs)
    XCTAssertTrue(chunkRecords.allSatisfy { $0.envelope?.ciphertext.isEmpty == false })
    let fetched = try await client.fetchLatestSnapshot(stationID: "station-mac-studio", now: now)
    XCTAssertEqual(fetched, snapshot)
  }

  func testFetchLatestSnapshotUsesDirectDeviceRecordWhenStationQueryIsEmpty() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let stagingDatabase = InMemoryMobileCloudMirrorDatabase()
    let writer = MobileCloudMirrorSnapshotWriter(
      database: stagingDatabase,
      snapshotCiphertextChunkSize: 512
    )
    let symmetricKey = Data(repeating: 14, count: 32)
    let identity = MobileDeviceIdentity(id: "device-phone", displayName: "Phone")
    let device = MobilePairingTrustedDevice(
      stationID: "station-mac-studio",
      deviceID: identity.id,
      displayName: identity.displayName,
      signingKeyFingerprint: try identity.signingKeyFingerprint(),
      signingPublicKeyRawRepresentation: try identity.signingPublicKeyRawRepresentation(),
      agreementPublicKeyRawRepresentation: Data([2]),
      snapshotKeyID: "snapshot-key",
      commandKeyID: "command-key",
      symmetricKeyRawRepresentation: symmetricKey,
      pairedAt: now
    )
    var snapshot = MobileDemoFixtures.snapshot(now: now)
    snapshot.revision = 101
    snapshot.taskBoardItems.append(
      MobileTaskBoardSummary(
        id: "task-direct-fetch",
        stationID: "station-mac-studio",
        title: "Large mirrored task",
        bodyPreview: String(repeating: "query empty direct fetch payload ", count: 300),
        status: "plan_review",
        statusTitle: "Plan Review",
        priority: "high",
        priorityTitle: "High",
        agentMode: "planning",
        needsYou: true,
        updatedAt: now
      )
    )

    let records = try await writer.writeSnapshot(
      snapshot,
      stationID: "station-mac-studio",
      devices: [device],
      now: now
    )
    let database = DirectOnlyMobileCloudMirrorDatabase(records: records)
    let client = MobileCloudMirrorSyncClient(
      database: database,
      cipher: MobilePayloadCipher(rawKey: symmetricKey),
      deviceIdentity: identity,
      commandKeyID: "command-key"
    )

    let fetched = try await client.fetchLatestSnapshot(
      stationID: "station-mac-studio",
      now: now
    )

    XCTAssertEqual(fetched, snapshot)
    let fetchAllCount = await database.fetchAllCount
    let fetchByIDCount = await database.fetchByIDCount
    XCTAssertEqual(fetchAllCount, 1)
    XCTAssertGreaterThan(fetchByIDCount, 1)
  }

  func testSnapshotWriterRetriesWithSmallerChunksWhenCloudKitRejectsLargeRecords() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = SizeLimitedMobileCloudMirrorDatabase(maxCiphertextBytes: 16 * 1024)
    let writer = MobileCloudMirrorSnapshotWriter(
      database: database,
      snapshotCiphertextChunkSize: 64 * 1024
    )
    let symmetricKey = Data(repeating: 13, count: 32)
    let device = MobilePairingTrustedDevice(
      stationID: "station-mac-studio",
      deviceID: "device-phone",
      displayName: "Phone",
      signingKeyFingerprint: "AA:BB:CC:DD",
      signingPublicKeyRawRepresentation: Data([1]),
      agreementPublicKeyRawRepresentation: Data([2]),
      snapshotKeyID: "snapshot-key",
      commandKeyID: "command-key",
      symmetricKeyRawRepresentation: symmetricKey,
      pairedAt: now
    )
    var snapshot = MobileDemoFixtures.snapshot(now: now)
    snapshot.revision = 100
    snapshot.taskBoardItems.append(
      MobileTaskBoardSummary(
        id: "task-too-large-for-first-chunk",
        stationID: "station-mac-studio",
        title: "Large mirrored task",
        bodyPreview: String(repeating: "large mirrored payload ", count: 5_000),
        status: "plan_review",
        statusTitle: "Plan Review",
        priority: "high",
        priorityTitle: "High",
        agentMode: "planning",
        needsYou: true,
        updatedAt: now
      )
    )

    let records = try await writer.writeSnapshot(
      snapshot,
      stationID: "station-mac-studio",
      devices: [device],
      now: now
    )
    let savedRecords = await database.savedRecords()
    let parent = try XCTUnwrap(records.first { $0.metadata.type == .snapshot })
    let client = MobileCloudMirrorSyncClient(
      database: database,
      cipher: MobilePayloadCipher(rawKey: symmetricKey),
      deviceIdentity: MobileDeviceIdentity(id: "device-phone", displayName: "Phone"),
      commandKeyID: "command-key"
    )
    let fetched = try await client.fetchLatestSnapshot(
      stationID: "station-mac-studio",
      now: now
    )

    XCTAssertFalse(parent.metadata.chunkIDs.isEmpty)
    XCTAssertTrue(savedRecords.allSatisfy { record in
      (record.envelope?.ciphertext.count ?? 0) <= 16 * 1024
    })
    XCTAssertEqual(fetched, snapshot)
  }

  func testSnapshotWriterTombstonesSupersededChunks() async throws {
    let firstWrite = Date(timeIntervalSince1970: 1_700_000_000)
    let secondWrite = firstWrite.addingTimeInterval(60)
    let database = InMemoryMobileCloudMirrorDatabase()
    let writer = MobileCloudMirrorSnapshotWriter(
      database: database,
      snapshotCiphertextChunkSize: 512
    )
    let symmetricKey = Data(repeating: 13, count: 32)
    let identity = MobileDeviceIdentity(id: "device-phone", displayName: "Phone")
    let device = MobilePairingTrustedDevice(
      stationID: "station-mac-studio",
      deviceID: identity.id,
      displayName: identity.displayName,
      signingKeyFingerprint: try identity.signingKeyFingerprint(),
      signingPublicKeyRawRepresentation: try identity.signingPublicKeyRawRepresentation(),
      agreementPublicKeyRawRepresentation: try identity.agreementPublicKeyRawRepresentation(),
      snapshotKeyID: "snapshot-key",
      commandKeyID: "command-key",
      symmetricKeyRawRepresentation: symmetricKey,
      pairedAt: firstWrite
    )
    var largeSnapshot = MobileDemoFixtures.snapshot(now: firstWrite)
    largeSnapshot.revision = 200
    largeSnapshot.taskBoardItems.append(
      MobileTaskBoardSummary(
        id: "task-large-superseded",
        stationID: "station-mac-studio",
        title: "Large mirrored task",
        bodyPreview: String(repeating: "large superseded payload ", count: 300),
        status: "plan_review",
        statusTitle: "Plan Review",
        priority: "high",
        priorityTitle: "High",
        agentMode: "planning",
        needsYou: true,
        updatedAt: firstWrite
      )
    )
    var compactSnapshot = MobileDemoFixtures.snapshot(now: secondWrite)
    compactSnapshot.revision = 201

    let firstRecords = try await writer.writeSnapshot(
      largeSnapshot,
      stationID: "station-mac-studio",
      devices: [device],
      now: firstWrite
    )
    let firstParent = try XCTUnwrap(firstRecords.first { $0.metadata.type == .snapshot })
    let compactWriter = MobileCloudMirrorSnapshotWriter(
      database: database,
      snapshotCiphertextChunkSize: 64 * 1024
    )
    let secondRecords = try await compactWriter.writeSnapshot(
      compactSnapshot,
      stationID: "station-mac-studio",
      devices: [device],
      now: secondWrite
    )
    let secondParent = try XCTUnwrap(secondRecords.first { $0.metadata.type == .snapshot })
    let client = MobileCloudMirrorSyncClient(
      database: database,
      cipher: MobilePayloadCipher(rawKey: symmetricKey),
      deviceIdentity: identity,
      commandKeyID: "command-key"
    )
    let fetched = try await client.fetchLatestSnapshot(
      stationID: "station-mac-studio",
      now: secondWrite
    )

    XCTAssertFalse(firstParent.metadata.chunkIDs.isEmpty)
    XCTAssertEqual(secondParent.metadata.chunkIDs, [])
    for chunkID in firstParent.metadata.chunkIDs {
      let storedRecord = try await database.fetch(recordID: chunkID)
      let record = try XCTUnwrap(storedRecord)
      XCTAssertEqual(record.metadata.type, .tombstone)
      XCTAssertTrue(record.metadata.tombstone)
      XCTAssertNil(record.envelope)
    }
    XCTAssertEqual(fetched, compactSnapshot)
  }
}

private actor DirectOnlyMobileCloudMirrorDatabase: MobileCloudMirrorDatabase {
  private var records: [String: MobileMirrorRecord]
  private(set) var fetchAllCount = 0
  private(set) var fetchByIDCount = 0

  init(records: [MobileMirrorRecord]) {
    self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
  }

  func save(_ record: MobileMirrorRecord) async throws {
    records[record.id] = record
  }

  func fetch(recordID: String) async throws -> MobileMirrorRecord? {
    fetchByIDCount += 1
    return records[recordID]
  }

  func fetchAll(stationID: String) async throws -> [MobileMirrorRecord] {
    fetchAllCount += 1
    return []
  }

  func delete(recordID: String) async throws {
    records.removeValue(forKey: recordID)
  }
}
