import Foundation

extension Error {
  var isTaskBoardPositionConflict: Bool {
    (self as? HarnessMonitorAPIError)?.isServerConflict == true
  }
}

extension HarnessMonitorStore {
  private static let taskBoardPositionConflictRetryLimit = 1

  /// Same-lane drag reorder: refetches the item's own CAS tokens immediately
  /// before sending the set, so the only staleness window is this one
  /// round-trip rather than however long the drag itself took.
  @discardableResult
  public func reorderTaskBoardItem(
    id: String,
    status: TaskBoardStatus,
    lanePosition: UInt32,
    actor: String = "Harness Monitor"
  ) async -> Bool {
    guard let client else { return false }
    beginDaemonAction()
    beginTaskBoardAction()
    defer {
      endDaemonAction()
      endTaskBoardAction()
    }
    do {
      let response = try await Self.measureOperation {
        try await Self.setTaskBoardItemPositionWithRetry(
          using: client,
          id: id,
          status: status,
          lanePosition: lanePosition,
          actor: actor,
          remainingRetries: Self.taskBoardPositionConflictRetryLimit
        )
      }.value
      recordRequestSuccess()
      mergeTaskBoardItem(response.snapshot.item)
      await refreshTaskBoardDashboardSnapshot(using: client)
      presentSuccessFeedback("Reordered task board item")
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      await refreshTaskBoardDashboardSnapshot(using: client)
      return false
    }
  }

  /// Reverts a manually placed item back to derived (priority/creation)
  /// ordering, clearing its manual provenance.
  @discardableResult
  public func resetTaskBoardItemManualPosition(
    id: String,
    actor: String = "Harness Monitor"
  ) async -> Bool {
    guard let client else { return false }
    beginDaemonAction()
    beginTaskBoardAction()
    defer {
      endDaemonAction()
      endTaskBoardAction()
    }
    do {
      let response = try await Self.measureOperation {
        try await Self.resetTaskBoardItemPositionWithRetry(
          using: client,
          id: id,
          actor: actor,
          remainingRetries: Self.taskBoardPositionConflictRetryLimit
        )
      }.value
      recordRequestSuccess()
      mergeTaskBoardItem(response.snapshot.item)
      await refreshTaskBoardDashboardSnapshot(using: client)
      presentSuccessFeedback("Reset task board position")
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      await refreshTaskBoardDashboardSnapshot(using: client)
      return false
    }
  }

  /// One bounded retry against a fresh snapshot when the daemon reports a
  /// concurrent-modification conflict on the item revision or the shared
  /// items-change sequence; any other failure surfaces immediately.
  nonisolated static func setTaskBoardItemPositionWithRetry(
    using client: any HarnessMonitorClientProtocol,
    id: String,
    status: TaskBoardStatus,
    lanePosition: UInt32,
    actor: String,
    remainingRetries: Int
  ) async throws -> TaskBoardItemPositionMutationResponse {
    let snapshot = try await client.taskBoardItemPositionSnapshot(id: id)
    let request = TaskBoardSetItemPositionRequest(
      status: status,
      lanePosition: lanePosition,
      expectedItemRevision: snapshot.itemRevision,
      expectedItemsChangeSeq: snapshot.itemsChangeSeq,
      actor: actor
    )
    do {
      return try await client.setTaskBoardItemPosition(id: id, request: request)
    } catch {
      guard remainingRetries > 0, error.isTaskBoardPositionConflict else { throw error }
      return try await setTaskBoardItemPositionWithRetry(
        using: client,
        id: id,
        status: status,
        lanePosition: lanePosition,
        actor: actor,
        remainingRetries: remainingRetries - 1
      )
    }
  }

  nonisolated static func resetTaskBoardItemPositionWithRetry(
    using client: any HarnessMonitorClientProtocol,
    id: String,
    actor: String,
    remainingRetries: Int
  ) async throws -> TaskBoardItemPositionMutationResponse {
    let snapshot = try await client.taskBoardItemPositionSnapshot(id: id)
    let request = TaskBoardResetItemPositionRequest(
      expectedItemRevision: snapshot.itemRevision,
      expectedItemsChangeSeq: snapshot.itemsChangeSeq,
      actor: actor
    )
    do {
      return try await client.resetTaskBoardItemPosition(id: id, request: request)
    } catch {
      guard remainingRetries > 0, error.isTaskBoardPositionConflict else { throw error }
      return try await resetTaskBoardItemPositionWithRetry(
        using: client,
        id: id,
        actor: actor,
        remainingRetries: remainingRetries - 1
      )
    }
  }
}
