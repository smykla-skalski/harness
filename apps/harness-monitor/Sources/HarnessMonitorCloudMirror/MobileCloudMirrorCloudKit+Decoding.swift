import CloudKit
import Foundation
import HarnessMonitorCore

extension MobileCloudMirrorCloudKitError {
  /// Per-record decode failures that a bulk fetch should skip rather than let
  /// poison the whole operation. An unknown `mirrorRecordType` (forward or
  /// backward schema skew: a record kind this build does not recognize) or a
  /// malformed field is skippable. `schemaUnavailable` and `partialFailure`
  /// are fetch-wide problems, not single bad records, so they still propagate.
  var isSkippableDecodeFailure: Bool {
    switch self {
    case .invalidField, .missingField:
      return true
    case .partialFailure, .schemaUnavailable:
      return false
    }
  }
}

extension MobileCloudMirrorCKRecordCodec {
  /// Decode a CloudKit query's match results into mirror records, skipping
  /// individual records that fail to decode so one unrecognized or malformed
  /// record cannot fail the entire fetch. Fetch-wide CloudKit failures still
  /// throw: a missing record type maps to `schemaUnavailable`, any other
  /// per-record `CKError` to `partialFailure`.
  public static func decodeMatchResults(
    _ results: [(CKRecord.ID, Result<CKRecord, any Error>)]
  ) throws -> [MobileMirrorRecord] {
    var decoded: [MobileMirrorRecord] = []
    for (_, result) in results {
      switch result {
      case .success(let record):
        do {
          decoded.append(try decode(record))
        } catch let error as MobileCloudMirrorCloudKitError where error.isSkippableDecodeFailure {
          continue
        }
      case .failure(let error as CKError)
      where MobileCloudMirrorCloudKitSchema.isMissingMirrorRecordType(error):
        throw MobileCloudMirrorCloudKitError.schemaUnavailable(
          MobileCloudMirrorCloudKitSchema.recordType
        )
      case .failure(let error):
        throw MobileCloudMirrorCloudKitError.partialFailure(String(describing: error))
      }
    }
    return decoded
  }
}
