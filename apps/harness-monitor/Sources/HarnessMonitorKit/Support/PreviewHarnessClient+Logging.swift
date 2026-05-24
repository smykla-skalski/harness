import Foundation

extension PreviewHarnessClient {
  public func logLevel() async throws -> LogLevelResponse {
    LogLevelResponse(
      level: HarnessMonitorLogger.defaultDaemonLogLevel,
      filter: HarnessMonitorLogger.defaultDaemonFilter
    )
  }

  public func setLogLevel(_ level: String) async throws -> LogLevelResponse {
    LogLevelResponse(level: level, filter: "harness=\(level)")
  }
}
