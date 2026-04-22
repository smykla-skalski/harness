import Foundation

/// Retention compaction for `SupervisorEvent`. Phase 1 no-op; Phase 2 worker 17 schedules via
/// `NSBackgroundActivityScheduler` and batch-deletes inside a SwiftData transaction.
public enum SupervisorAuditRetention {
  public static func compactOlderThan(_ age: TimeInterval) async {
    _ = age
  }
}
