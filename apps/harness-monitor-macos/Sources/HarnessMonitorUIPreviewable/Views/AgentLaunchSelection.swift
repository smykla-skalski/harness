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

  var preferredRuntime: AgentTuiRuntime {
    switch self {
    case .tui(let runtime):
      runtime
    case .acp(let id):
      AgentTuiRuntime(rawValue: id) ?? .copilot
    }
  }

  init?(storageKey: String) {
    let tuiRuntime = Self.parseTuiRuntime(storageKey: storageKey)
    if let runtime = tuiRuntime {
      self = .tui(runtime)
      return
    }

    if let agentID = storageKey.stripPrefix("managed:"), !agentID.isEmpty {
      self = .acp(agentID)
      return
    }

    return nil
  }

  private static func parseTuiRuntime(storageKey: String) -> AgentTuiRuntime? {
    storageKey
      .stripPrefix("tui:")
      .flatMap(AgentTuiRuntime.init(rawValue:))
  }
}

extension String {
  fileprivate func stripPrefix(_ prefix: String) -> String? {
    guard hasPrefix(prefix) else { return nil }
    return String(dropFirst(prefix.count))
  }
}
