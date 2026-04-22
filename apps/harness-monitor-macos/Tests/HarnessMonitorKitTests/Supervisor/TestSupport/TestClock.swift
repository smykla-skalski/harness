import Foundation

@testable import HarnessMonitorKit

/// Placeholder manual clock for the Monitor supervisor tick-loop tests. Phase 2 worker 5
/// (SupervisorService) fills in the continuation registry and advance semantics. Phase 1 just
/// owns the symbol so test files in other units can reference `TestClock` without redeclaring
/// it.
final class TestClock: @unchecked Sendable {
  /// Current virtual time. Starts at `Date()` and Phase 2 code will tick it forward on
  /// `advance(by:)`.
  var now = Date()

  /// Advance the virtual clock by the given duration. Phase 1 no-op.
  func advance(by duration: Duration) async {
    _ = duration
  }
}
