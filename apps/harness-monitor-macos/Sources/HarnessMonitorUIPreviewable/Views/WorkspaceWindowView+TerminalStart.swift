import HarnessMonitorKit

extension WorkspaceWindowView {
  func startTerminalAgent() async {
    if await startAcpAgentIfSelected() {
      return
    }

    let selectedRuntime = viewModel.selectedLaunchSelection.preferredRuntime
    let startSize =
      viewModel.lastMeasuredViewportSize
      ?? viewModel.lastDetailColumnSize.map {
        TerminalViewportSizing.estimatedStartSize(
          detailColumnSize: $0,
          fontScale: fontScale,
          fallbackRows: viewModel.rows
        )
      }
      ?? AgentTuiSize(rows: viewModel.rows, cols: viewModel.cols)
    syncTerminalResizeControls(to: startSize)
    viewModel.expectedSize = startSize
    let catalog = viewModel.availableRuntimeModels.first {
      $0.runtime == selectedRuntime.rawValue
    }
    let pickerValue =
      viewModel.selectedTerminalModelByRuntime[selectedRuntime]
      ?? catalog?.default
      ?? ""
    let customValue = viewModel.customTerminalModelByRuntime[selectedRuntime] ?? ""
    let resolved = WorkspaceWindowView.effectiveModelId(
      pickerValue: pickerValue,
      customValue: customValue,
      catalogDefault: catalog?.default ?? ""
    )
    let effort = viewModel.selectedTerminalEffortByRuntime[selectedRuntime]
    guard
      let startedTui = await store.startAgentTuiSnapshot(
        runtime: selectedRuntime,
        role: viewModel.selectedRole,
        name: viewModel.name,
        prompt: viewModel.prompt,
        projectDir: trimmedProjectDir,
        persona: viewModel.selectedPersona,
        model: resolved.id,
        effort: effort,
        allowCustomModel: resolved.allowCustom,
        argv: parsedArgvOverride,
        rows: startSize.rows,
        cols: startSize.cols,
        sessionID: resolvedCreateSessionID
      )
    else {
      return
    }
    resetTerminalCreateForm(startedTui: startedTui)
  }

  private func resetTerminalCreateForm(startedTui: AgentTuiSnapshot) {
    viewModel.name = ""
    viewModel.prompt = ""
    viewModel.projectDir = ""
    viewModel.argvOverride = ""
    viewModel.inputText = ""
    viewModel.selectedPersona = nil
    viewModel.selectedRole = .worker
    viewModel.selection = .terminal(
      sessionID: startedTui.sessionId,
      terminalID: startedTui.tuiId
    )
    focusedField = .input
  }
}
