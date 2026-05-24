public enum HarnessMonitorMCPRuntimeState: Equatable, Sendable {
  case disabled
  case starting(socketPath: String?)
  case healthy(socketPath: String)
  case degraded(socketPath: String?, reason: String)

  public var socketPath: String? {
    switch self {
    case .disabled:
      nil
    case .starting(let socketPath):
      socketPath
    case .healthy(let socketPath):
      socketPath
    case .degraded(let socketPath, _):
      socketPath
    }
  }

  public var reason: String? {
    switch self {
    case .degraded(_, let reason):
      reason
    case .disabled, .starting, .healthy:
      nil
    }
  }
}

@MainActor
public protocol HarnessMonitorMCPStartupControlling: AnyObject {
  var runtimeState: HarnessMonitorMCPRuntimeState { get }
  func setEnabled(_ enabled: Bool) async
  func probeRuntimeState() async -> HarnessMonitorMCPRuntimeState
}
