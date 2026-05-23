import Foundation

/// Deterministic content hash of an Open Anything corpus.
///
/// Hashing the built `[OpenAnythingRecord]` array directly eliminates the
/// field-drift problem the hand-curated `hashSessions / hashTaskBoard / ...`
/// helpers had: every field that goes into a record automatically contributes
/// to the signature, because `OpenAnythingRecord` is `Hashable` and the
/// synthesized conformance covers all stored properties.
public enum OpenAnythingCorpusSignature {
  public static func compute(_ records: [OpenAnythingRecord]) -> Int {
    var hasher = Hasher()
    hasher.combine(records.count)
    for record in records {
      hasher.combine(record)
    }
    return hasher.finalize()
  }
}
