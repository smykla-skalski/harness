import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto

extension MobileCloudMirrorSyncClient {
  func fetchDirectDeviceSnapshot(
    stationID: String,
    now: Date
  ) async throws -> MobileMirrorSnapshot? {
    guard let recordID = try? directDeviceSnapshotRecordID(stationID: stationID),
      let record = try await database.fetch(recordID: recordID),
      record.metadata.type == .snapshot,
      !record.metadata.tombstone,
      record.metadata.stationID == stationID
    else {
      return nil
    }
    guard record.metadata.expiresAt > now else {
      throw MobileCloudMirrorSyncError.staleSnapshot(record.metadata.expiresAt)
    }

    let directRecords = try await directSnapshotRecords(for: record)
    guard
      let snapshot = try openSnapshotRecord(
        record,
        allRecords: directRecords,
        now: now
      )
    else {
      return nil
    }

    let stationRecords = (try? await database.fetchAll(stationID: stationID)) ?? []
    let mergeRecords = recordsByID(directRecords + stationRecords)
    return snapshot.mergingMobileCommandRecords(
      commands: decryptableCommandRecords(in: mergeRecords, stationID: stationID, now: now),
      receipts: decryptableReceiptRecords(in: mergeRecords, stationID: stationID, now: now),
      now: now
    )
  }

  func openSnapshotRecord(
    _ record: MobileMirrorRecord,
    allRecords records: [MobileMirrorRecord],
    now: Date
  ) throws -> MobileMirrorSnapshot? {
    guard var envelope = record.envelope else {
      throw MobileCloudMirrorSyncError.missingSnapshotEnvelope(record.id)
    }
    guard
      envelope.additionalAuthenticatedData
        == MobileCloudMirrorRecordAAD.data(for: record.metadata)
    else {
      return nil
    }
    if !record.metadata.chunkIDs.isEmpty {
      guard let ciphertext = chunkedCiphertext(for: record, allRecords: records, now: now) else {
        return nil
      }
      envelope.ciphertext = ciphertext
    }
    guard let snapshot: MobileMirrorSnapshot = try? cipher.open(envelope),
      snapshot.expiresAt > now
    else {
      return nil
    }
    return snapshot
  }

  private func directDeviceSnapshotRecordID(stationID: String) throws -> String {
    try MobileCloudMirrorSnapshotWriter.snapshotRecordID(
      stationID: stationID,
      deviceID: deviceIdentity.id,
      signingKeyFingerprint: deviceIdentity.signingKeyFingerprint()
    )
  }

  private func directSnapshotRecords(
    for record: MobileMirrorRecord
  ) async throws -> [MobileMirrorRecord] {
    let chunkIDs = record.metadata.chunkIDs
    guard !chunkIDs.isEmpty else {
      return [record]
    }
    let database = self.database
    let chunks = try await withThrowingTaskGroup(
      of: (offset: Int, chunk: MobileMirrorRecord?).self
    ) { group in
      for (offset, chunkID) in chunkIDs.enumerated() {
        group.addTask {
          (offset, try await database.fetch(recordID: chunkID))
        }
      }
      var fetched: [(offset: Int, chunk: MobileMirrorRecord)] = []
      for try await result in group {
        if let chunk = result.chunk {
          fetched.append((result.offset, chunk))
        }
      }
      return fetched.sorted { $0.offset < $1.offset }.map(\.chunk)
    }
    return [record] + chunks
  }

  private func recordsByID(_ records: [MobileMirrorRecord]) -> [MobileMirrorRecord] {
    var orderedIDs: [String] = []
    var recordsByID: [String: MobileMirrorRecord] = [:]
    for record in records {
      if recordsByID[record.id] == nil {
        orderedIDs.append(record.id)
      }
      recordsByID[record.id] = record
    }
    return orderedIDs.compactMap { recordsByID[$0] }
  }

  private func chunkedCiphertext(
    for snapshotRecord: MobileMirrorRecord,
    allRecords records: [MobileMirrorRecord],
    now: Date
  ) -> Data? {
    let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    var ciphertext = Data()
    for chunkID in snapshotRecord.metadata.chunkIDs {
      guard
        let chunk = recordsByID[chunkID],
        chunk.metadata.type == .snapshotChunk,
        chunk.metadata.stationID == snapshotRecord.metadata.stationID,
        chunk.metadata.revision == snapshotRecord.metadata.revision,
        !chunk.metadata.tombstone,
        chunk.metadata.expiresAt > now,
        let envelope = chunk.envelope
      else {
        return nil
      }
      ciphertext.append(envelope.ciphertext)
    }
    return ciphertext
  }
}
