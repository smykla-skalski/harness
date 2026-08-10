import Foundation

extension HarnessMonitorStore {
  func readTaskBoard<Value: Sendable>(
    _ operation: @escaping @Sendable (any HarnessMonitorClientProtocol) async throws -> Value
  ) async -> Value? {
    guard connectionState == .online, let access = availableTaskBoardClientAccess else {
      return nil
    }
    do {
      let measuredValue = try await Self.measureOperation {
        try await operation(access.client)
      }
      try requireCurrentTaskBoardClientAccess(access)
      recordRequestSuccess()
      return measuredValue.value
    } catch is CancellationError {
      return nil
    } catch {
      guard (try? requireCurrentTaskBoardClientAccess(access)) != nil else {
        return nil
      }
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }
}
