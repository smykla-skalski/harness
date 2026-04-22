import Foundation

/// Bridges `PolicyAction`s from rules to the daemon API (`HarnessMonitorAPIClient`) and to the
/// `DecisionStore`. Phase 1 signature freeze: the `init` and `execute` surface is fixed. Phase
/// 2 worker 4 fills the routing table, audit-before-action ordering, and sliding-window dedup.
public actor PolicyExecutor {
  private let decisions: DecisionStore
  private let audit: InMemoryAuditWriterBridge?

  public init(
    api: Any?,
    decisions: DecisionStore,
    audit: Any?
  ) {
    // Phase 1 no-op: Phase 2 worker 4 replaces `Any?` with `any HarnessMonitorAPIProtocol` and
    // the concrete audit writer protocol once those surfaces land.
    _ = api
    self.decisions = decisions
    self.audit = audit as? InMemoryAuditWriterBridge
  }

  /// Phase 1 stub: always reports `skippedDuplicate` so the tick loop tolerates being called
  /// before Phase 2 routes actions. Phase 2 worker 4 replaces the body with the real audit +
  /// dispatch + dedup pipeline.
  public func execute(_ action: PolicyAction) async -> PolicyOutcome {
    .skippedDuplicate(actionKey: action.actionKey)
  }
}

/// Phase 1 placeholder bridge — the real audit writer protocol lives alongside Phase 2 worker
/// 4's PolicyExecutor body. Keeping the bridge as a type alias here lets tests pass the
/// in-memory writer through without a compile break.
public typealias InMemoryAuditWriterBridge = AnyObject

extension PolicyExecutor {
  /// Convenience factory used in Phase 2 tests. Phase 1 ships the fixture so call sites that
  /// reference it (as the source plan's Task 8 sample test does) compile immediately. Phase 2
  /// worker 4 replaces the body with the real in-memory container setup.
  public static func fixture() throws -> PolicyExecutor {
    PolicyExecutor(
      api: nil,
      decisions: try DecisionStore.makeInMemory(),
      audit: nil
    )
  }
}
