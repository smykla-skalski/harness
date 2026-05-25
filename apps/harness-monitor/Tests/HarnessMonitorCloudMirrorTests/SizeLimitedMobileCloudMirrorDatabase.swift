import CloudKit
import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore

actor SizeLimitedMobileCloudMirrorDatabase: MobileCloudMirrorDatabase {
  private let maxCiphertextBytes: Int
  private var records: [String: MobileMirrorRecord] = [:]

  init(maxCiphertextBytes: Int) {
    self.maxCiphertextBytes = maxCiphertextBytes
  }

  func save(_ record: MobileMirrorRecord) async throws {
    if (record.envelope?.ciphertext.count ?? 0) > maxCiphertextBytes {
      throw CKError(.limitExceeded)
    }
    records[record.id] = record
  }

  func fetch(recordID: String) async throws -> MobileMirrorRecord? {
    records[recordID]
  }

  func fetchAll(stationID: String) async throws -> [MobileMirrorRecord] {
    records.values
      .filter { $0.metadata.stationID == stationID }
      .sorted { $0.metadata.updatedAt > $1.metadata.updatedAt }
  }

  func delete(recordID: String) async throws {
    records.removeValue(forKey: recordID)
  }

  func savedRecords() -> [MobileMirrorRecord] {
    records.values.sorted { $0.id < $1.id }
  }
}
