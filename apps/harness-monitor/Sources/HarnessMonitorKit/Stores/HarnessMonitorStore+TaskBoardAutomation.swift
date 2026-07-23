import Foundation

extension HarnessMonitorStore {
  public func taskBoardAutomationRuns(
    before: String? = nil,
    limit: UInt32 = 50
  ) async -> TaskBoardAutomationHistoryResponse? {
    guard connectionState == .online, let client else { return nil }
    do {
      let measuredResponse = try await Self.measureOperation {
        try await client.taskBoardAutomationRuns(
          request: TaskBoardAutomationHistoryRequest(limit: limit, before: before)
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

  public func taskBoardAutomationRunDetail(
    runID: String
  ) async -> TaskBoardAutomationRunDetail? {
    guard connectionState == .online, let client else { return nil }
    do {
      let measuredDetail = try await Self.measureOperation {
        try await client.taskBoardAutomationRunDetail(runID: runID)
      }
      recordRequestSuccess()
      return measuredDetail.value
    } catch is CancellationError {
      return nil
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }

  public func taskBoardAutomationMetrics() async -> TaskBoardAutomationMetrics? {
    guard connectionState == .online, let client else { return nil }
    do {
      let measuredMetrics = try await Self.measureOperation {
        try await client.taskBoardAutomationMetrics()
      }
      recordRequestSuccess()
      return measuredMetrics.value
    } catch is CancellationError {
      return nil
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }

  @discardableResult
  public func forceCancelTaskBoardAutomation(
    request: TaskBoardAutomationForceCancelRequest
  ) async -> Bool {
    guard connectionState == .online, let client else { return false }
    guard isCurrentForceCancelTarget(request.target) else {
      presentFailureFeedback("Cancellation target changed. Refresh and try again.")
      return false
    }

    beginDaemonAction()
    beginTaskBoardAction()
    defer {
      endDaemonAction()
      endTaskBoardAction()
    }

    do {
      let measuredResponse = try await Self.measureOperation {
        try await client.forceCancelTaskBoardAutomation(request: request)
      }
      recordRequestSuccess()
      await refreshTaskBoardDashboardSnapshot(using: client)
      presentSuccessFeedback(Self.forceCancelSuccessMessage(measuredResponse.value.disposition))
      return true
    } catch is CancellationError {
      return false
    } catch {
      await refreshTaskBoardDashboardSnapshot(using: client)
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  func mergeTaskBoardAutomationSnapshot(_ snapshot: TaskBoardAutomationSnapshot?) {
    guard let snapshot else { return }
    if let current = globalTaskBoardAutomationSnapshot,
      !Self.isNewerAutomationSnapshot(snapshot, than: current)
    {
      return
    }
    globalTaskBoardAutomationSnapshot = snapshot
  }

  private static func isNewerAutomationSnapshot(
    _ candidate: TaskBoardAutomationSnapshot,
    than current: TaskBoardAutomationSnapshot
  ) -> Bool {
    if candidate.revision != current.revision {
      return candidate.revision > current.revision
    }
    let candidateDate = try? Date(candidate.observedAt, strategy: .iso8601)
    let currentDate = try? Date(current.observedAt, strategy: .iso8601)
    switch (candidateDate, currentDate) {
    case (.some(let candidateDate), .some(let currentDate)):
      return candidateDate > currentDate
    case (.some, .none):
      return true
    case (.none, .some):
      return false
    case (.none, .none):
      return candidate.observedAt > current.observedAt
    }
  }

  private func isCurrentForceCancelTarget(
    _ target: TaskBoardAutomationCancelTarget
  ) -> Bool {
    !target.cancelPending
      && globalTaskBoardAutomationSnapshot?.cancelableTargets.contains(target) == true
  }

  private static func forceCancelSuccessMessage(
    _ disposition: TaskBoardAutomationForceCancelDisposition
  ) -> String {
    switch disposition {
    case .acceptedPending, .replayedPending:
      "Cancellation requested"
    case .cancelled, .replayedCancelled:
      "Workflow cancelled"
    case .unknown:
      "Cancellation accepted"
    }
  }
}
