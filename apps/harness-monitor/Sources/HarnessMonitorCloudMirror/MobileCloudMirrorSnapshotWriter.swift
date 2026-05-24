import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto

public actor MobileCloudMirrorSnapshotWriter {
  private let database: any MobileCloudMirrorDatabase
  private let retention: TimeInterval

  public init(
    database: any MobileCloudMirrorDatabase,
    retention: TimeInterval = MobileCloudMirrorSchema.sevenDayRetention
  ) {
    self.database = database
    self.retention = retention
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
      let metadata = MobileMirrorRecordMetadata(
        id: Self.snapshotRecordID(stationID: stationID, device: device),
        type: .snapshot,
        stationID: stationID,
        revision: snapshot.revision,
        updatedAt: snapshot.generatedAt,
        expiresAt: min(snapshot.expiresAt, now.addingTimeInterval(retention))
      )
      let cipher = MobilePayloadCipher(rawKey: device.symmetricKeyRawRepresentation)
      let envelope = try cipher.seal(
        snapshot,
        keyID: device.snapshotKeyID,
        additionalAuthenticatedData: MobileCloudMirrorRecordAAD.data(for: metadata),
        createdAt: now
      )
      let record = MobileMirrorRecord(metadata: metadata, envelope: envelope)
      try await database.save(record)
      records.append(record)
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
}
