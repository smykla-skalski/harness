import Foundation

/// Deterministic content hash of an Open Anything corpus.
///
/// Hashing the built `[OpenAnythingRecord]` array directly eliminates the
/// field-drift problem the hand-curated `hashSessions / hashTaskBoard / ...`
/// helpers had: every field that goes into a record automatically contributes
/// to the signature, because `OpenAnythingRecord` is `Hashable` and the
/// synthesized conformance covers all stored properties.
public enum OpenAnythingCorpusSignature {
  /// Stable salt mixed into every signature so two unrelated empty inputs in
  /// the same process cannot collide with neighbouring use of `Hasher`. The
  /// value is arbitrary; it just needs to be a non-zero compile-time
  /// constant.
  public static let salt: UInt64 = 0x4F70_656E_416E_7974

  public static func compute(_ records: [OpenAnythingRecord]) -> Int {
    var hasher = Hasher()
    hasher.combine(salt)
    hasher.combine(records.count)
    for record in records {
      hasher.combine(record)
    }
    return hasher.finalize()
  }
}
