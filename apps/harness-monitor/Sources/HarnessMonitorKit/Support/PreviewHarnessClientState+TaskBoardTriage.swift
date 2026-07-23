import Foundation

extension PreviewHarnessClientState {
  /// Preview/test hook: replaces the newest-first decision history for one
  /// item id. Not part of the client protocol -- callers seed fixtures
  /// through this before exercising `taskBoardItemTriageCurrent`/`History`.
  func seedTaskBoardTriageDecisions(id: String, decisions: [TaskBoardTriageDecisionRecord]) {
    taskBoardTriageDecisionsByItemID[id] = decisions
  }

  func taskBoardItemTriageCurrent(id: String) throws -> TaskBoardTriageCurrentResponse {
    _ = try currentTaskBoardItem(id: id)
    return TaskBoardTriageCurrentResponse(current: taskBoardTriageDecisionsByItemID[id]?.first)
  }

  func taskBoardItemTriageHistory(
    id: String,
    beforeGeneration: UInt64?,
    limit: UInt32?
  ) throws -> TaskBoardTriageHistoryResponse {
    _ = try currentTaskBoardItem(id: id)
    guard
      beforeGeneration.isNoneOrPositiveAndInRange,
      limit.isNoneOrValidTriageHistoryLimit
    else {
      throw HarnessMonitorAPIError.semanticServer(
        code: 400,
        semanticCode: "WORKFLOW_IO",
        message: "invalid task-board triage history params"
      )
    }
    let decisions = taskBoardTriageDecisionsByItemID[id] ?? []
    let boundedLimit = Int(limit ?? 50)
    let page =
      decisions
      .filter { decision in
        beforeGeneration.map { decision.generation < $0 } ?? true
      }
      .prefix(boundedLimit + 1)
    let hasMore = page.count > boundedLimit
    let returned = Array(page.prefix(boundedLimit))
    return TaskBoardTriageHistoryResponse(
      decisions: returned,
      nextBeforeGeneration: hasMore ? returned.last?.generation : nil
    )
  }
}

extension Optional where Wrapped == UInt64 {
  fileprivate var isNoneOrPositiveAndInRange: Bool {
    map { $0 > 0 && $0 <= UInt64(Int64.max) } ?? true
  }
}

extension Optional where Wrapped == UInt32 {
  fileprivate var isNoneOrValidTriageHistoryLimit: Bool {
    map { (1...100).contains($0) } ?? true
  }
}
