import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto

extension MobileCloudMirrorSyncClient {
  func decryptableCommandRecords(
    in records: [MobileMirrorRecord],
    stationID: String,
    now: Date
  ) -> [MobileCommandRecord] {
    records
      .filter {
        $0.metadata.type == .command
          && !$0.metadata.tombstone
          && $0.metadata.expiresAt > now
      }
      .compactMap { record in
        decryptableCommand(record, stationID: stationID)
      }
  }

  func canCancelCommandFromThisActor(_ command: MobileCommandRecord) -> Bool {
    command.actorDeviceID == actorDeviceID
      || MobileCommandActorDeviceID.trustedBaseDeviceID(for: command.actorDeviceID)
        == MobileCommandActorDeviceID.trustedBaseDeviceID(for: actorDeviceID)
  }

  func decryptableReceiptRecords(
    in records: [MobileMirrorRecord],
    stationID: String,
    now: Date
  ) -> [MobileCommandReceipt] {
    records
      .filter {
        $0.metadata.type == .receipt
          && !$0.metadata.tombstone
          && $0.metadata.expiresAt > now
      }
      .compactMap { record -> MobileCommandReceipt? in
        guard let envelope = record.envelope,
          envelope.additionalAuthenticatedData
            == MobileCloudMirrorRecordAAD.data(for: record.metadata)
        else {
          return nil
        }
        guard let receipt = try? cipher.open(envelope, as: MobileCommandReceipt.self),
          receipt.stationID == stationID
        else {
          return nil
        }
        return receipt
      }
  }

  private func decryptableCommand(
    _ record: MobileMirrorRecord,
    stationID: String
  ) -> MobileCommandRecord? {
    guard let signingKeyFingerprint = try? deviceIdentity.signingKeyFingerprint(),
      let signingPublicKey = try? deviceIdentity.signingPublicKeyRawRepresentation()
    else {
      return nil
    }
    guard let envelope = record.envelope,
      envelope.additionalAuthenticatedData == MobileCloudMirrorRecordAAD.data(for: record.metadata),
      let signedCommand: MobileSignedCommand = try? cipher.open(envelope),
      isCommandReadableByThisDevice(signedCommand.command),
      signedCommand.signingKeyFingerprint == signingKeyFingerprint,
      (try? MobileCommandSigner.verify(
        signedCommand,
        publicKeyRawRepresentation: signingPublicKey
      )) == true
    else {
      return nil
    }
    guard signedCommand.command.stationID == stationID,
      signedCommand.command.id == record.id
    else {
      return nil
    }
    return signedCommand.command
  }

  private func isCommandReadableByThisDevice(_ command: MobileCommandRecord) -> Bool {
    command.actorDeviceID == actorDeviceID
      || MobileCommandActorDeviceID.isTrustedActor(
        command.actorDeviceID,
        for: deviceIdentity.id
      )
  }
}
