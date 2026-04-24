import HarnessMonitorKit

extension AgentsWindowView {
  func resolvedTitle(for tui: AgentTuiSnapshot) -> String {
    displayState.sessionTitlesByID[tui.tuiId] ?? resolvedRuntimeTitle(for: tui)
  }

  func resolvedRuntimeTitle(for tui: AgentTuiSnapshot) -> String {
    Self.runtimeTitle(for: tui)
  }

  func resolvedTitle(for run: CodexRunSnapshot) -> String {
    displayState.codexTitlesByID[run.runId] ?? Self.codexTitle(for: run)
  }

  static func runtimeTitle(for tui: AgentTuiSnapshot) -> String {
    if let runtime = AgentTuiRuntime(rawValue: tui.runtime) {
      return runtime.title
    }

    if let suffix = tui.agentId.split(separator: "-").last, !suffix.isEmpty {
      return "Agent \(suffix)"
    }

    return tui.runtime.capitalized
  }

  static func codexTitle(for run: CodexRunSnapshot) -> String {
    AgentTuiDisplayState.codexTitle(for: run)
  }
}
