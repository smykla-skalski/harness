import CloudKit
import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import XCTest

final class MobileCloudMirrorSnapshotChunkConcurrencyTests: XCTestCase {
  func testChunkRecordsAreFetchedConcurrently() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let stagingDatabase = InMemoryMobileCloudMirrorDatabase()
    let writer = MobileCloudMirrorSnapshotWriter(
      database: stagingDatabase,
      snapshotCiphertextChunkSize: 512
    )
    let symmetricKey = Data(repeating: 21, count: 32)
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
    snapshot.revision = 202
    snapshot.taskBoardItems.append(
      MobileTaskBoardSummary(
        id: "task-chunked",
        stationID: "station-mac-studio",
        title: "Large mirrored task",
        bodyPreview: String(repeating: "concurrent chunk fetch payload ", count: 300),
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
    XCTAssertGreaterThanOrEqual(
      parent.metadata.chunkIDs.count,
      3,
      "the fixture must span several chunks to prove overlap"
    )

    let database = ChunkConcurrencyProbeDatabase(records: records)
    let client = MobileCloudMirrorSyncClient(
      database: database,
      cipher: MobilePayloadCipher(rawKey: symmetricKey),
      deviceIdentity: identity,
      commandKeyID: "command-key"
    )

    let fetched = try await client.fetchLatestSnapshot(stationID: "station-mac-studio", now: now)

    XCTAssertEqual(fetched, snapshot, "concurrent assembly still reconstructs the snapshot exactly")
    let chunkFetchCount = await database.chunkFetchCount
    let maxConcurrent = await database.maxConcurrentChunkFetches
    XCTAssertEqual(
      chunkFetchCount,
      parent.metadata.chunkIDs.count,
      "every chunk is still fetched by id, none collapsed into a query"
    )
    XCTAssertGreaterThan(
      maxConcurrent,
      1,
      "chunk records overlap in flight rather than fetching one at a time"
    )
  }
}

private actor ChunkConcurrencyProbeDatabase: MobileCloudMirrorDatabase {
  private var records: [String: MobileMirrorRecord]
  private var inFlightChunkFetches = 0
  private(set) var maxConcurrentChunkFetches = 0
  private(set) var chunkFetchCount = 0

  init(records: [MobileMirrorRecord]) {
    self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
  }

  func save(_ record: MobileMirrorRecord) async throws {
    records[record.id] = record
  }

  func fetch(recordID: String) async throws -> MobileMirrorRecord? {
    let record = records[recordID]
    guard record?.metadata.type == .snapshotChunk else {
      return record
    }
    chunkFetchCount += 1
    inFlightChunkFetches += 1
    maxConcurrentChunkFetches = max(maxConcurrentChunkFetches, inFlightChunkFetches)
    try? await Task.sleep(for: .milliseconds(25))
    inFlightChunkFetches -= 1
    return record
  }

  func fetchAll(stationID: String) async throws -> [MobileMirrorRecord] {
    records.values
      .filter { $0.metadata.stationID == stationID }
      .sorted { $0.metadata.updatedAt > $1.metadata.updatedAt }
  }

  func delete(recordID: String) async throws {
    records.removeValue(forKey: recordID)
  }
}
