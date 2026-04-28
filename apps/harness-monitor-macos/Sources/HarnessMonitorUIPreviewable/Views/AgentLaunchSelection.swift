import HarnessMonitorKit

enum AgentLaunchSelection: Hashable, Sendable {
  case tui(AgentTuiRuntime)
  case acp(String)

  var storageKey: String {
    switch self {
    case .tui(let runtime):
      "tui:\(runtime.rawValue)"
    case .acp(let id):
      "managed:\(id)"
    }
  }
}
