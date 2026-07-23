import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func taskBoardItemTriageCurrent(id: String) async throws -> TaskBoardTriageCurrentResponse {
    return lock.withLock {
      TaskBoardTriageCurrentResponse(current: taskBoardTriageDecisionsStorage[id]?.first)
    }
  }

  func taskBoardItemTriageHistory(
    id: String,
    beforeGeneration: UInt64?,
    limit: UInt32?
  ) async throws -> TaskBoardTriageHistoryResponse {
    guard
      beforeGeneration.map({ $0 > 0 && $0 <= UInt64(Int64.max) }) ?? true,
      limit.map({ (1...100).contains($0) }) ?? true
    else {
      throw HarnessMonitorAPIError.semanticServer(
        code: 400,
        semanticCode: "WORKFLOW_IO",
        message: "invalid task-board triage history params"
      )
    }
    return lock.withLock {
      let decisions = taskBoardTriageDecisionsStorage[id] ?? []
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
}
