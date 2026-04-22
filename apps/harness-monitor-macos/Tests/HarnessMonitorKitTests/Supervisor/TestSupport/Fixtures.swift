import Foundation

@testable import HarnessMonitorKit

/// Shared fixture helpers for the Monitor supervisor test suite. Phase 1 only ships placeholder
/// extensions so later units can import a single symbol (`Fixtures`) without chasing definitions
/// across commits. Phase 2 workers grow these on demand, never speculatively.
enum Fixtures {}

extension Date {
  /// A deterministic timestamp used as `now` across supervisor tests so snapshot hashes are
  /// reproducible.
  static var fixed: Date { Date(timeIntervalSince1970: 1_700_000_000) }
}
