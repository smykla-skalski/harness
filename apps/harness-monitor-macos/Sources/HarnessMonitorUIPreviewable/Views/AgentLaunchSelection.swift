import HarnessMonitorKit

enum AgentLaunchSelection: Hashable, Sendable {
  case tui(AgentTuiRuntime)
  case acp(String)

  var isAcp: Bool {
    if case .acp = self {
      return true
    }
    return false
  }

  var storageKey: String {
    switch self {
    case .tui(let runtime):
      "tui:\(runtime.rawValue)"
    case .acp(let id):
      "managed:\(id)"
    }
  }

  var accessibilityIDComponent: String {
    storageKey
  }
}
