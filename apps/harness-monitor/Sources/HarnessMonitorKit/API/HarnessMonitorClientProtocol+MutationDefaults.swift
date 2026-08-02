import Foundation

extension HarnessMonitorClientProtocol {
  public func deleteSession(sessionID _: String) async throws {
    throw HarnessMonitorAPIError.server(code: 501, message: "Session deletion unavailable")
  }

  public func archiveSession(
    sessionID _: String,
    request _: SessionArchiveRequest
  ) async throws -> SessionArchiveResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Session removal unavailable")
  }

  public func deleteTask(
    sessionID _: String,
    taskID _: String,
    request _: TaskDeleteRequest
  ) async throws -> SessionDetail {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task deletion unavailable")
  }
}
