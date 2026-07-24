import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func taskBoardItemTriageCurrent(id: String) async throws -> TaskBoardTriageCurrentResponse {
    return lock.withLock {
      let current = taskBoardTriageDecisionsStorage[id]?.first
      let triageOverride = taskBoardTriageOverridesStorage[id]
      let effective =
        triageOverride.map {
          TaskBoardTriageEffectiveOutcome(verdict: $0.verdict, source: .override)
        }
        ?? current.map {
          TaskBoardTriageEffectiveOutcome(verdict: $0.verdict, source: .automatic)
        }
      return TaskBoardTriageCurrentResponse(
        current: current,
        triageOverride: triageOverride,
        effective: effective
      )
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

  func setTaskBoardItemTriageOverride(
    id: String,
    request: TaskBoardSetTriageOverrideRequest
  ) async throws -> TaskBoardTriageOverrideMutationResponse {
    try lock.withLock {
      taskBoardTriageOverrideSetRequests.append(request)
      try throwQueuedTriageOverrideErrorIfNeeded()
      try ensureExpectedTriageOverrideState(
        id: id,
        expectedItemRevision: request.expectedItemRevision,
        expectedItemsChangeSeq: request.expectedItemsChangeSeq
      )
      let triageOverride = TaskBoardTriageOverride(
        verdict: request.verdict,
        actor: request.actor,
        reason: request.reason,
        setAt: "2026-07-23T15:00:00Z"
      )
      taskBoardTriageOverridesStorage[id] = triageOverride
      return try triageOverrideMutationResponse(
        id: id,
        triageOverride: triageOverride,
        effective: TaskBoardTriageEffectiveOutcome(
          verdict: request.verdict,
          source: .override
        )
      )
    }
  }

  func clearTaskBoardItemTriageOverride(
    id: String,
    request: TaskBoardClearTriageOverrideRequest
  ) async throws -> TaskBoardTriageOverrideMutationResponse {
    try lock.withLock {
      taskBoardTriageOverrideClearRequests.append(request)
      try throwQueuedTriageOverrideErrorIfNeeded()
      try ensureExpectedTriageOverrideState(
        id: id,
        expectedItemRevision: request.expectedItemRevision,
        expectedItemsChangeSeq: request.expectedItemsChangeSeq
      )
      taskBoardTriageOverridesStorage.removeValue(forKey: id)
      let current = taskBoardTriageDecisionsStorage[id]?.first
      return try triageOverrideMutationResponse(
        id: id,
        triageOverride: nil,
        effective: current.map {
          TaskBoardTriageEffectiveOutcome(verdict: $0.verdict, source: .automatic)
        }
      )
    }
  }

  private func throwQueuedTriageOverrideErrorIfNeeded() throws {
    guard
      taskBoardTriageOverrideErrorRemainingUses > 0,
      let error = taskBoardTriageOverrideError
    else {
      return
    }
    taskBoardTriageOverrideErrorRemainingUses -= 1
    applyTriageOverrideItemsAfterErrorIfNeeded()
    throw error
  }

  private func applyTriageOverrideItemsAfterErrorIfNeeded() {
    guard let replacement = taskBoardTriageOverrideItemsAfterError else { return }
    let previousByID = Dictionary(uniqueKeysWithValues: taskBoardItemsStorage.map { ($0.id, $0) })
    for item in replacement where previousByID[item.id] != item {
      taskBoardItemRevisionsStorage[item.id, default: 1] += 1
    }
    taskBoardItemsStorage = replacement
    taskBoardItemsChangeSeqStorage += 1
    taskBoardTriageOverrideItemsAfterError = nil
  }

  private func ensureExpectedTriageOverrideState(
    id: String,
    expectedItemRevision: Int64,
    expectedItemsChangeSeq: Int64
  ) throws {
    guard
      taskBoardItemRevisionsStorage[id, default: 1] == expectedItemRevision,
      taskBoardItemsChangeSeqStorage == expectedItemsChangeSeq
    else {
      throw HarnessMonitorAPIError.semanticServer(
        code: 409,
        semanticCode: "WORKFLOW_CONCURRENT",
        message: "Task board triage override is stale"
      )
    }
  }

  private func triageOverrideMutationResponse(
    id: String,
    triageOverride: TaskBoardTriageOverride?,
    effective: TaskBoardTriageEffectiveOutcome?
  ) throws -> TaskBoardTriageOverrideMutationResponse {
    guard let item = taskBoardItemsStorage.first(where: { $0.id == id }) else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Task board item unavailable.")
    }
    let revision = taskBoardItemRevisionsStorage[id, default: 1] + 1
    taskBoardItemRevisionsStorage[id] = revision
    taskBoardItemsChangeSeqStorage += 1
    return TaskBoardTriageOverrideMutationResponse(
      snapshot: TaskBoardItemPositionSnapshot(
        item: item,
        itemRevision: revision,
        itemsChangeSeq: taskBoardItemsChangeSeqStorage
      ),
      shifted: [],
      triageOverride: triageOverride,
      effective: effective
    )
  }
}
