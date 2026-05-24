import Foundation

extension PreviewHarnessClient {
  public func deleteTask(
    sessionID: String,
    taskID: String,
    request _: TaskDeleteRequest
  ) async throws -> SessionDetail {
    try await performActionDelay()
    return try await state.deleteTask(sessionID: sessionID, taskID: taskID)
  }
}
