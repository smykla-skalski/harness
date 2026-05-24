import Foundation

struct OpenAnythingPaletteCorpusCache {
  static let empty = Self(
    suggestedRecords: [],
    recordsByID: [:]
  )

  let suggestedRecords: [OpenAnythingRecord]
  private let recordsByID: [String: OpenAnythingRecord]

  init(records: [OpenAnythingRecord]) {
    var suggestedRecords: [OpenAnythingRecord] = []
    suggestedRecords.reserveCapacity(records.count)
    var recordsByID: [String: OpenAnythingRecord] = [:]
    recordsByID.reserveCapacity(records.count)

    for record in records {
      recordsByID[record.id] = record
      if record.isSuggested {
        suggestedRecords.append(record)
      }
    }

    self.suggestedRecords = suggestedRecords
    self.recordsByID = recordsByID
  }

  private init(
    suggestedRecords: [OpenAnythingRecord],
    recordsByID: [String: OpenAnythingRecord]
  ) {
    self.suggestedRecords = suggestedRecords
    self.recordsByID = recordsByID
  }

  func record(id: String) -> OpenAnythingRecord? {
    recordsByID[id]
  }
}
