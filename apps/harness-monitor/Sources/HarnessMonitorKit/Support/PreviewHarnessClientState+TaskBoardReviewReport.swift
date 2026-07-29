import Foundation

extension PreviewHarnessClientState {
  func taskBoardItemReviewReport(id: String) throws -> TaskBoardAiReviewReportResponse {
    _ = try currentTaskBoardItem(id: id)
    return taskBoardReviewReportsByItemID[id] ?? .notStarted
  }

  static func seededTaskBoardReviewReports(
    items: [TaskBoardItem]
  ) -> [String: TaskBoardAiReviewReportResponse] {
    Dictionary(
      uniqueKeysWithValues: items.compactMap { item in
        guard item.workflowKind == .prReview || item.workflowKind == .review else {
          return nil
        }
        let report = TaskBoardAiReviewReportRecord(
          reportId: "preview-review-\(item.id)",
          itemId: item.id,
          correlationId: "preview-correlation-\(item.id)",
          repository: item.executionRepository ?? "example/harness",
          pullRequestNumber: item.workflow?.prNumber ?? 901,
          headRevision: String(repeating: "a", count: 40),
          runtime: "openrouter",
          requestedModel: "deepseek/deepseek-v4-flash",
          effectiveModel: "deepseek/deepseek-v4-flash",
          status: .completed,
          summary: "The selected revision is ready for human review.",
          findings: [
            TaskBoardReportOnlyReviewFinding(
              severity: .medium,
              location: TaskBoardReviewFindingLocation(
                path: "src/review.rs",
                line: 42
              ),
              evidence: "The retry path does not preserve the original correlation id."
            )
          ],
          startedAt: "2026-07-29T19:40:00Z",
          finishedAt: "2026-07-29T19:41:12Z"
        )
        return (item.id, .completed(report: report))
      }
    )
  }
}
