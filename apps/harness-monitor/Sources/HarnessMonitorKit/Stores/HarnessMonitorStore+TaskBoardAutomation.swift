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
}
