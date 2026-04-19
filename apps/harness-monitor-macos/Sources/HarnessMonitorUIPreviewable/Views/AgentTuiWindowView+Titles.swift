import HarnessMonitorKit

extension AgentTuiWindowView {
  func refreshDisplayState() {
    let nextState = AgentTuiDisplayState(store: store)
    guard viewModel.displayState != nextState else {
      return
    }
    viewModel.displayState = nextState
  }

  func resolvedTitle(for tui: AgentTuiSnapshot) -> String {
    viewModel.displayState.sessionTitlesByID[tui.tuiId] ?? resolvedRuntimeTitle(for: tui)
  }

  func resolvedRuntimeTitle(for tui: AgentTuiSnapshot) -> String {
    Self.runtimeTitle(for: tui)
  }

  func resolvedTitle(for run: CodexRunSnapshot) -> String {
    viewModel.displayState.codexTitlesByID[run.runId] ?? Self.codexTitle(for: run)
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
