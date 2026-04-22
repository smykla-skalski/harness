import Foundation

@testable import HarnessMonitorKit

/// Minimal placeholder fake for the Monitor supervisor test suite. Phase 2 workers (unit 4,
/// PolicyExecutor) extend this with the surface they need. Phase 1 ships the scaffold only so
/// every test file has a single symbol to import without spreading fake definitions across
/// unrelated commits.
final class FakeAPIClient: @unchecked Sendable {
  struct NudgeCall: Equatable, Sendable {
    let agentID: String
    let input: String
  }

  /// Nudge invocations recorded by the fake. Phase 1 defines the field because the plan's
  /// sample test body in Task 8 references it; the field stays empty until Phase 2 implements
  /// the routing path.
  var nudgeCalls: [NudgeCall] = []
}
