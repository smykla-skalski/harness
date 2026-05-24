import Foundation

extension SessionSnapshot {
  @MainActor
  static func summaryOnly(summary: SessionSummary) -> Self {
    Self(
      id: summary.sessionId,
      title: summary.title,
      statusRaw: summary.status.rawValue,
      agents: [],
      tasks: [],
      timelineDensityLastMinute: 0,
      observerIssues: [],
      pendingCodexApprovals: []
    )
  }
}
