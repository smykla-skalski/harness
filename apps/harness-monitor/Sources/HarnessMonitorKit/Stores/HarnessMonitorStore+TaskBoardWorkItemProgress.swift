import Foundation

extension HarnessMonitorStore {
  public func taskBoardItemProgress(id: String) async -> TaskBoardWorkItemProgressResponse? {
    guard connectionState == .online, let client else { return nil }
    do {
      let measuredResponse = try await Self.measureOperation {
        try await client.taskBoardItemProgress(id: id)
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
