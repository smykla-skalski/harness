import CloudKit
import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto

public actor MobileCloudMirrorSnapshotWriter {
  public static let defaultSnapshotCiphertextChunkSize = 256 * 1024
  private static let minimumSnapshotCiphertextChunkSize = 16 * 1024
  private static let chunkedParentCiphertextSentinel = Data([0])

  private let database: any MobileCloudMirrorDatabase
  private let retention: TimeInterval
  private let snapshotCiphertextChunkSize: Int

  public init(
    database: any MobileCloudMirrorDatabase,
    retention: TimeInterval = MobileCloudMirrorSchema.sevenDayRetention,
    snapshotCiphertextChunkSize: Int = MobileCloudMirrorSnapshotWriter
      .defaultSnapshotCiphertextChunkSize
  ) {
    self.database = database
    self.retention = retention
    self.snapshotCiphertextChunkSize = max(1, snapshotCiphertextChunkSize)
  }

  @discardableResult
  public func writeSnapshot(
    _ snapshot: MobileMirrorSnapshot,
    stationID: String,
    devices: [MobilePairingTrustedDevice],
    now: Date = .now
  ) async throws -> [MobileMirrorRecord] {
    let pairedDevices = devices
      .filter { $0.stationID == stationID }
      .deduplicatedSnapshotRecipients()
    var records: [MobileMirrorRecord] = []
    records.reserveCapacity(pairedDevices.count)

    for device in pairedDevices {
      let deviceRecords = try await writeSnapshot(
        snapshot,
        stationID: stationID,
        device: device,
        now: now
      )
      records.append(contentsOf: deviceRecords)
    }

    return records
  }

  private func writeSnapshot(
    _ snapshot: MobileMirrorSnapshot,
    stationID: String,
    device: MobilePairingTrustedDevice,
    now: Date
  ) async throws -> [MobileMirrorRecord] {
    var chunkSize = snapshotCiphertextChunkSize
    while true {
      do {
        return try await writeSnapshot(
          snapshot,
          stationID: stationID,
          device: device,
          now: now,
          chunkSize: chunkSize
        )
      } catch
        where Self.isCloudKitRecordTooLarge(error)
        && chunkSize > Self.minimumSnapshotCiphertextChunkSize
      {
        chunkSize = max(Self.minimumSnapshotCiphertextChunkSize, chunkSize / 2)
      }
    }
  }

  private func writeSnapshot(
    _ snapshot: MobileMirrorSnapshot,
    stationID: String,
    device: MobilePairingTrustedDevice,
    now: Date,
    chunkSize: Int
  ) async throws -> [MobileMirrorRecord] {
    let snapshotRecordID = Self.snapshotRecordID(stationID: stationID, device: device)
    let previousChunkIDs =
      try await database.fetch(recordID: snapshotRecordID)?
      .metadata.chunkIDs ?? []
    let baseMetadata = metadata(
      id: snapshotRecordID,
      type: .snapshot,
      stationID: stationID,
      snapshot: snapshot,
      now: now
    )
    let cipher = MobilePayloadCipher(rawKey: device.symmetricKeyRawRepresentation)
    let sizingEnvelope = try cipher.seal(
      snapshot,
      keyID: device.snapshotKeyID,
      additionalAuthenticatedData: MobileCloudMirrorRecordAAD.data(for: baseMetadata),
      createdAt: now
    )
    let chunkIDs = Self.chunkRecordIDs(
      snapshotRecordID: snapshotRecordID,
      ciphertextLength: sizingEnvelope.ciphertext.count,
      chunkSize: chunkSize
    )
    let metadata = self.metadata(
      id: snapshotRecordID,
      type: .snapshot,
      stationID: stationID,
      snapshot: snapshot,
      now: now,
      chunkIDs: chunkIDs
    )
    let envelope = try cipher.seal(
      snapshot,
      keyID: device.snapshotKeyID,
      additionalAuthenticatedData: MobileCloudMirrorRecordAAD.data(for: metadata),
      createdAt: now
    )
    let chunkRecords = Self.chunkRecords(
      envelope: envelope,
      parentMetadata: metadata,
      chunkIDs: chunkIDs,
      chunkSize: chunkSize
    )
    for chunkRecord in chunkRecords {
      try await database.save(chunkRecord)
    }
    let record = MobileMirrorRecord(
      metadata: metadata,
      envelope: Self.parentEnvelope(envelope, hasChunks: !chunkIDs.isEmpty)
    )
    try await database.save(record)

    var records = [record]
    records.append(contentsOf: chunkRecords)
    let staleChunkRecords = try await tombstoneStaleChunks(
      previousChunkIDs: previousChunkIDs,
      currentChunkIDs: chunkIDs,
      stationID: stationID,
      revision: snapshot.revision,
      now: now
    )
    records.append(contentsOf: staleChunkRecords)
    return records
  }

  private func tombstoneStaleChunks(
    previousChunkIDs: [String],
    currentChunkIDs: [String],
    stationID: String,
    revision: Int64,
    now: Date
  ) async throws -> [MobileMirrorRecord] {
    let currentChunkIDs = Set(currentChunkIDs)
    let staleChunkIDs = previousChunkIDs.filter { !currentChunkIDs.contains($0) }
    guard !staleChunkIDs.isEmpty else {
      return []
    }

    var tombstones: [MobileMirrorRecord] = []
    tombstones.reserveCapacity(staleChunkIDs.count)
    for chunkID in staleChunkIDs {
      let tombstone = MobileMirrorRecord(
        metadata: MobileMirrorRecordMetadata(
          id: chunkID,
          type: .tombstone,
          stationID: stationID,
          revision: revision,
          updatedAt: now,
          expiresAt: now.addingTimeInterval(retention),
          tombstone: true
        ),
        envelope: nil
      )
      try await database.save(tombstone)
      tombstones.append(tombstone)
    }
    return tombstones
  }

  private func metadata(
    id: String,
    type: MobileMirrorRecordType,
    stationID: String,
    snapshot: MobileMirrorSnapshot,
    now: Date,
    chunkIDs: [String] = []
  ) -> MobileMirrorRecordMetadata {
    MobileMirrorRecordMetadata(
      id: id,
      type: type,
      stationID: stationID,
      revision: snapshot.revision,
      updatedAt: snapshot.generatedAt,
      expiresAt: min(snapshot.expiresAt, now.addingTimeInterval(retention)),
      chunkIDs: chunkIDs
    )
  }

  nonisolated private static func isCloudKitRecordTooLarge(_ error: any Error) -> Bool {
    if let error = error as? CKError {
      return error.code == .limitExceeded
    }
    let nsError = error as NSError
    guard nsError.domain == CKError.errorDomain else {
      return false
    }
    return CKError.Code(rawValue: nsError.code) == .limitExceeded
  }

  nonisolated public static func snapshotRecordID(
    stationID: String,
    device: MobilePairingTrustedDevice
  ) -> String {
    snapshotRecordID(
      stationID: stationID,
      deviceID: device.deviceID,
      signingKeyFingerprint: device.signingKeyFingerprint
    )
  }

  nonisolated public static func snapshotRecordID(
    stationID: String,
    deviceID: String,
    signingKeyFingerprint: String
  ) -> String {
    let recipient = "\(stationID)|\(deviceID)|\(signingKeyFingerprint)"
    let recipientHash = MobileCryptoFingerprint.fingerprint(Data(recipient.utf8))
      .replacingOccurrences(of: ":", with: "")
      .lowercased()
    return "snapshot-\(stationID)-\(recipientHash)"
  }

  nonisolated public static func chunkRecordIDs(
    snapshotRecordID: String,
    ciphertextLength: Int,
    chunkSize: Int = MobileCloudMirrorSnapshotWriter.defaultSnapshotCiphertextChunkSize
  ) -> [String] {
    let chunkSize = max(1, chunkSize)
    guard ciphertextLength > chunkSize else {
      return []
    }
    let chunkCount = (ciphertextLength + chunkSize - 1) / chunkSize
    return (0..<chunkCount).map { "\(snapshotRecordID)-chunk-\($0)" }
  }

  nonisolated private static func parentEnvelope(
    _ envelope: MobileEncryptedEnvelope,
    hasChunks: Bool
  ) -> MobileEncryptedEnvelope {
    guard hasChunks else {
      return envelope
    }
    var parentEnvelope = envelope
    parentEnvelope.ciphertext = chunkedParentCiphertextSentinel
    return parentEnvelope
  }

  nonisolated private static func chunkRecords(
    envelope: MobileEncryptedEnvelope,
    parentMetadata: MobileMirrorRecordMetadata,
    chunkIDs: [String],
    chunkSize: Int
  ) -> [MobileMirrorRecord] {
    guard !chunkIDs.isEmpty else {
      return []
    }
    var chunks: [MobileMirrorRecord] = []
    chunks.reserveCapacity(chunkIDs.count)
    var offset = envelope.ciphertext.startIndex
    for chunkID in chunkIDs {
      let nextOffset =
        envelope.ciphertext.index(
          offset,
          offsetBy: chunkSize,
          limitedBy: envelope.ciphertext.endIndex
        ) ?? envelope.ciphertext.endIndex
      var chunkEnvelope = envelope
      chunkEnvelope.ciphertext = envelope.ciphertext[offset..<nextOffset]
      chunks.append(
        MobileMirrorRecord(
          metadata: MobileMirrorRecordMetadata(
            id: chunkID,
            type: .snapshotChunk,
            stationID: parentMetadata.stationID,
            schemaVersion: parentMetadata.schemaVersion,
            revision: parentMetadata.revision,
            updatedAt: parentMetadata.updatedAt,
            expiresAt: parentMetadata.expiresAt
          ),
          envelope: chunkEnvelope
        )
      )
      offset = nextOffset
    }
    return chunks
  }
}

extension Array where Element == MobilePairingTrustedDevice {
  fileprivate func deduplicatedSnapshotRecipients() -> Self {
    var seen: Set<String> = []
    var result: [Element] = []
    result.reserveCapacity(count)
    for device in self {
      let key = "\(device.deviceID)|\(device.signingKeyFingerprint)"
      guard seen.insert(key).inserted else {
        continue
      }
      result.append(device)
    }
    return result
  }
}
