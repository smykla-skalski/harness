import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto

public actor MobileCloudMirrorSnapshotWriter {
  public static let defaultSnapshotCiphertextChunkSize = 256 * 1024
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
    let pairedDevices = devices.filter { $0.stationID == stationID }
    var records: [MobileMirrorRecord] = []
    records.reserveCapacity(pairedDevices.count)

    for device in pairedDevices {
      let snapshotRecordID = Self.snapshotRecordID(stationID: stationID, device: device)
      let baseMetadata = MobileMirrorRecordMetadata(
        id: snapshotRecordID,
        type: .snapshot,
        stationID: stationID,
        revision: snapshot.revision,
        updatedAt: snapshot.generatedAt,
        expiresAt: min(snapshot.expiresAt, now.addingTimeInterval(retention))
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
        chunkSize: snapshotCiphertextChunkSize
      )
      let metadata = MobileMirrorRecordMetadata(
        id: snapshotRecordID,
        type: .snapshot,
        stationID: stationID,
        revision: snapshot.revision,
        updatedAt: snapshot.generatedAt,
        expiresAt: min(snapshot.expiresAt, now.addingTimeInterval(retention)),
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
        chunkSize: snapshotCiphertextChunkSize
      )
      for chunkRecord in chunkRecords {
        try await database.save(chunkRecord)
      }
      let record = MobileMirrorRecord(
        metadata: metadata,
        envelope: Self.parentEnvelope(envelope, hasChunks: !chunkIDs.isEmpty)
      )
      try await database.save(record)
      records.append(record)
      records.append(contentsOf: chunkRecords)
    }

    return records
  }

  public nonisolated static func snapshotRecordID(
    stationID: String,
    device: MobilePairingTrustedDevice
  ) -> String {
    let recipient = "\(stationID)|\(device.deviceID)|\(device.signingKeyFingerprint)"
    let recipientHash = MobileCryptoFingerprint.fingerprint(Data(recipient.utf8))
      .replacingOccurrences(of: ":", with: "")
      .lowercased()
    return "snapshot-\(stationID)-\(recipientHash)"
  }

  public nonisolated static func chunkRecordIDs(
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

  private nonisolated static func parentEnvelope(
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

  private nonisolated static func chunkRecords(
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
      let nextOffset = envelope.ciphertext.index(
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
