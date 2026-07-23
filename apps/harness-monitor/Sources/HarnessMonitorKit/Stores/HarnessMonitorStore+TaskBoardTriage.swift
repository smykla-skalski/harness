import Foundation

extension HarnessMonitorStore {
  public func taskBoardItemTriageCurrent(id: String) async -> TaskBoardTriageCurrentResponse? {
    guard connectionState == .online, let client else { return nil }
    do {
      let measuredResponse = try await Self.measureOperation {
        try await client.taskBoardItemTriageCurrent(id: id)
      }
      recordRequestSuccess()
      return measuredResponse.value
    } catch is CancellationError {
      return nil
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }

  public func taskBoardItemTriageHistory(
    id: String,
    beforeGeneration: UInt64? = nil,
    limit: UInt32? = nil
  ) async -> TaskBoardTriageHistoryResponse? {
    guard connectionState == .online, let client else { return nil }
    do {
      let measuredResponse = try await Self.measureOperation {
        try await client.taskBoardItemTriageHistory(
          id: id,
          beforeGeneration: beforeGeneration,
          limit: limit
        )
      }
      recordRequestSuccess()
      return measuredResponse.value
    } catch is CancellationError {
      return nil
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }

  @discardableResult
  public func setTaskBoardItemTriageOverride(
    id: String,
    request: TaskBoardSetTriageOverrideRequest
  ) async -> Bool {
    await mutateTaskBoardTriageOverride(actionName: "Set triage override") { client in
      try await client.setTaskBoardItemTriageOverride(id: id, request: request)
    }
  }

  @discardableResult
  public func clearTaskBoardItemTriageOverride(
    id: String,
    request: TaskBoardClearTriageOverrideRequest
  ) async -> Bool {
    await mutateTaskBoardTriageOverride(actionName: "Clear triage override") { client in
      try await client.clearTaskBoardItemTriageOverride(id: id, request: request)
    }
  }

  private func mutateTaskBoardTriageOverride(
    actionName: String,
    operation:
      @escaping @Sendable (any HarnessMonitorClientProtocol) async throws
      -> TaskBoardTriageOverrideMutationResponse
  ) async -> Bool {
    guard let client else { return false }
    beginDaemonAction()
    beginTaskBoardAction()
    defer {
      endDaemonAction()
      endTaskBoardAction()
    }
    do {
      let response = try await Self.measureOperation { try await operation(client) }.value
      recordRequestSuccess()
      mergeTaskBoardItem(response.snapshot.item)
      await refreshTaskBoardDashboardSnapshot(using: client)
      presentSuccessFeedback(actionName)
      return true
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
    await mutateTaskBoardTriageOverride(actionName: "Set triage override") { client in
      try await Self.setTaskBoardTriageOverrideWithRetry(
        using: client,
        id: id,
        verdict: verdict,
        reason: reason,
        actor: actor,
        remainingRetries: Self.taskBoardTriageOverrideConflictRetryLimit
      )
    }
  }

  /// Clears with the same item-revision-preserving retry rule as set.
  @discardableResult
  public func clearTaskBoardItemTriageOverride(
    id: String,
    actor: String = "Harness Monitor"
  ) async -> Bool {
    await mutateTaskBoardTriageOverride(actionName: "Clear triage override") { client in
      try await Self.clearTaskBoardTriageOverrideWithRetry(
        using: client,
        id: id,
        actor: actor,
        remainingRetries: Self.taskBoardTriageOverrideConflictRetryLimit
      )
    }
  }

  private static let taskBoardTriageOverrideConflictRetryLimit = 1

  private static func setTaskBoardTriageOverrideWithRetry(
    using client: any HarnessMonitorClientProtocol,
    id: String,
    verdict: TriageVerdict,
    reason: String?,
    actor: String,
    remainingRetries: Int
  ) async throws -> TaskBoardTriageOverrideMutationResponse {
    var snapshot = try await client.taskBoardItemPositionSnapshot(id: id)
    let initialItemRevision = snapshot.itemRevision
    var retries = remainingRetries
    while true {
      let request = TaskBoardSetTriageOverrideRequest(
        verdict: verdict,
        reason: reason,
        expectedItemRevision: snapshot.itemRevision,
        expectedItemsChangeSeq: snapshot.itemsChangeSeq,
        actor: actor
      )
      do {
        return try await client.setTaskBoardItemTriageOverride(id: id, request: request)
      } catch {
        guard retries > 0, error.isTaskBoardTriageOverrideConcurrentModification else {
          throw error
        }
        let refreshed = try await client.taskBoardItemPositionSnapshot(id: id)
        guard refreshed.itemRevision == initialItemRevision else {
          throw error
        }
        snapshot = refreshed
        retries -= 1
      }
    }
  }

  private static func clearTaskBoardTriageOverrideWithRetry(
    using client: any HarnessMonitorClientProtocol,
    id: String,
    actor: String,
    remainingRetries: Int
  ) async throws -> TaskBoardTriageOverrideMutationResponse {
    var snapshot = try await client.taskBoardItemPositionSnapshot(id: id)
    let initialItemRevision = snapshot.itemRevision
    var retries = remainingRetries
    while true {
      let request = TaskBoardClearTriageOverrideRequest(
        expectedItemRevision: snapshot.itemRevision,
        expectedItemsChangeSeq: snapshot.itemsChangeSeq,
        actor: actor
      )
      do {
        return try await client.clearTaskBoardItemTriageOverride(id: id, request: request)
      } catch {
        guard retries > 0, error.isTaskBoardTriageOverrideConcurrentModification else {
          throw error
        }
        let refreshed = try await client.taskBoardItemPositionSnapshot(id: id)
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
  fileprivate var isTaskBoardTriageOverrideConcurrentModification: Bool {
    (self as? HarnessMonitorAPIError)?.serverSemanticCode == "WORKFLOW_CONCURRENT"
  }
}
