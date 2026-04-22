import Foundation

/// JSONL exporter for `SupervisorEvent` and `Decision` rows. Phase 1 ships no-op methods so
/// Preferences and menu commands can wire buttons; Phase 2 worker 16 fills the streaming body.
public enum SupervisorAuditExporter {
  public static func exportEvents(toURL url: URL, filter: String? = nil) async throws {
    _ = (url, filter)
  }

  public static func exportDecisions(toURL url: URL, filter: String? = nil) async throws {
    _ = (url, filter)
  }
}
