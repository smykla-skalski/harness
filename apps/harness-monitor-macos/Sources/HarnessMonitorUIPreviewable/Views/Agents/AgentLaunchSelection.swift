import HarnessMonitorKit

enum AgentLaunchSelection: Hashable, Sendable {
  case codex
  case tui(AgentTuiRuntime)
  case acp(String)

  var isAcp: Bool {
    if case .acp = self {
      return true
    }
    return false
  }

  var isCodexNative: Bool {
    if case .codex = self {
      return true
    }
    return false
  }

  var isManagedControlPlane: Bool {
    isAcp || isCodexNative
  }

  var storageKey: String {
    switch self {
    case .codex:
      "codex"
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
    case .codex:
      .codex
    case .tui(let runtime):
      runtime
    case .acp(let id):
      AgentTuiRuntime(rawValue: id) ?? .copilot
    }
  }

  init?(storageKey: String) {
    if storageKey == "codex" {
      self = .codex
      return
    }

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
