import Foundation

extension HarnessMonitorStore {
  public func taskBoardItemTriageCurrent(id: String) async -> TaskBoardTriageCurrentResponse? {
    await readTaskBoard { client in
      try await client.taskBoardItemTriageCurrent(id: id)
    }
  }

  public func taskBoardItemTriageHistory(
    id: String,
    beforeGeneration: UInt64? = nil,
    limit: UInt32? = nil
  ) async -> TaskBoardTriageHistoryResponse? {
    await readTaskBoard { client in
      try await client.taskBoardItemTriageHistory(
        id: id,
        beforeGeneration: beforeGeneration,
        limit: limit
      )
    }
  }

  @discardableResult
  public func setTaskBoardItemTriageOverride(
    id: String,
    request: TaskBoardSetTriageOverrideRequest
  ) async -> Bool {
    await mutateTaskBoardTriageOverride(actionName: "Set triage override") { [self] access in
      try requireCurrentTaskBoardClientAccess(access)
      return try await access.client.setTaskBoardItemTriageOverride(id: id, request: request)
    }
  }

  @discardableResult
  public func clearTaskBoardItemTriageOverride(
    id: String,
    request: TaskBoardClearTriageOverrideRequest
  ) async -> Bool {
    await mutateTaskBoardTriageOverride(actionName: "Clear triage override") { [self] access in
      try requireCurrentTaskBoardClientAccess(access)
      return try await access.client.clearTaskBoardItemTriageOverride(id: id, request: request)
    }
  }

  private func mutateTaskBoardTriageOverride(
    actionName: String,
    operation:
      @escaping @MainActor @Sendable (TaskBoardClientAccess) async throws
      -> TaskBoardTriageOverrideMutationResponse
  ) async -> Bool {
    guard let access = availableTaskBoardClientAccess else { return false }
    let client = access.client
    beginDaemonAction()
    beginTaskBoardAction()
    defer {
      endDaemonAction()
      endTaskBoardAction()
    }
    do {
      let response = try await Self.measureOperation { try await operation(access) }.value
      try requireCurrentTaskBoardClientAccess(access)
      recordRequestSuccess()
      mergeTaskBoardItem(response.snapshot.item)
      await refreshTaskBoardDashboardSnapshot(using: client)
      presentSuccessFeedback(actionName)
      return true
    } catch is CancellationError {
      return false
    } catch {
      presentFailureFeedback(error.localizedDescription)
      await refreshTaskBoardDashboardSnapshot(using: client)
      return false
    }
  }

  /// Fetches fresh CAS tokens immediately before setting the override.
  /// Retries one global-sequence race only while this item's revision is
  /// unchanged, so a competing override is never overwritten silently.
  @discardableResult
  public func setTaskBoardItemTriageOverride(
    id: String,
    verdict: TriageVerdict,
    reason: String?,
    actor: String = "Harness Monitor"
  ) async -> Bool {
    await mutateTaskBoardTriageOverride(actionName: "Set triage override") { [self] access in
      try await setTaskBoardTriageOverrideWithRetry(
        access: access,
        id: id,
        SetTriageOverrideParams(verdict: verdict, reason: reason, actor: actor),
        remainingRetries: Self.triageOverrideConflictRetryLimit
      )
    }
  }

  /// Clears with the same item-revision-preserving retry rule as set.
  @discardableResult
  public func clearTaskBoardItemTriageOverride(
    id: String,
    actor: String = "Harness Monitor"
  ) async -> Bool {
    await mutateTaskBoardTriageOverride(actionName: "Clear triage override") { [self] access in
      try await clearTaskBoardTriageOverrideWithRetry(
        access: access,
        id: id,
        actor: actor,
        remainingRetries: Self.triageOverrideConflictRetryLimit
      )
    }
  }

  private static let triageOverrideConflictRetryLimit = 1

  private struct SetTriageOverrideParams {
    let verdict: TriageVerdict
    let reason: String?
    let actor: String
  }

  private func setTaskBoardTriageOverrideWithRetry(
    access: TaskBoardClientAccess,
    id: String,
    _ params: SetTriageOverrideParams,
    remainingRetries: Int
  ) async throws -> TaskBoardTriageOverrideMutationResponse {
    try requireCurrentTaskBoardClientAccess(access)
    let client = access.client
    var snapshot = try await client.taskBoardItemPositionSnapshot(id: id)
    try requireCurrentTaskBoardClientAccess(access)
    let initialItemRevision = snapshot.itemRevision
    var retries = remainingRetries
    while true {
      let request = TaskBoardSetTriageOverrideRequest(
        verdict: params.verdict,
        reason: params.reason,
        expectedItemRevision: snapshot.itemRevision,
        expectedItemsChangeSeq: snapshot.itemsChangeSeq,
        actor: params.actor
      )
      do {
        try requireCurrentTaskBoardClientAccess(access)
        return try await client.setTaskBoardItemTriageOverride(id: id, request: request)
      } catch {
        try requireCurrentTaskBoardClientAccess(access)
        guard retries > 0, error.isTriageOverrideConcurrentModification else {
          throw error
        }
        let refreshed = try await client.taskBoardItemPositionSnapshot(id: id)
        try requireCurrentTaskBoardClientAccess(access)
        guard refreshed.itemRevision == initialItemRevision else {
          throw error
        }
        snapshot = refreshed
        retries -= 1
      }
    }
  }

  private func clearTaskBoardTriageOverrideWithRetry(
    access: TaskBoardClientAccess,
    id: String,
    actor: String,
    remainingRetries: Int
  ) async throws -> TaskBoardTriageOverrideMutationResponse {
    try requireCurrentTaskBoardClientAccess(access)
    let client = access.client
    var snapshot = try await client.taskBoardItemPositionSnapshot(id: id)
    try requireCurrentTaskBoardClientAccess(access)
    let initialItemRevision = snapshot.itemRevision
    var retries = remainingRetries
    while true {
      let request = TaskBoardClearTriageOverrideRequest(
        expectedItemRevision: snapshot.itemRevision,
        expectedItemsChangeSeq: snapshot.itemsChangeSeq,
        actor: actor
      )
      do {
        try requireCurrentTaskBoardClientAccess(access)
        return try await client.clearTaskBoardItemTriageOverride(id: id, request: request)
      } catch {
        try requireCurrentTaskBoardClientAccess(access)
        guard retries > 0, error.isTriageOverrideConcurrentModification else {
          throw error
        }
        let refreshed = try await client.taskBoardItemPositionSnapshot(id: id)
        try requireCurrentTaskBoardClientAccess(access)
        guard refreshed.itemRevision == initialItemRevision else {
          throw error
        }
        snapshot = refreshed
        retries -= 1
      }
    }
  }
}

extension Error {
  fileprivate var isTriageOverrideConcurrentModification: Bool {
    (self as? HarnessMonitorAPIError)?.serverSemanticCode == "WORKFLOW_CONCURRENT"
  }
}
