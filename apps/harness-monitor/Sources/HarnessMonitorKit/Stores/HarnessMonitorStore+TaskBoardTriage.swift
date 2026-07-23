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
}
