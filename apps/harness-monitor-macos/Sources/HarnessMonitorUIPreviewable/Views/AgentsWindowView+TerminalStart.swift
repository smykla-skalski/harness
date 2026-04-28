import HarnessMonitorKit

extension AgentsWindowView {
  func startTerminalAgent() async {
    if await startAcpAgentIfSelected() {
      return
    }

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
      $0.runtime == viewModel.runtime.rawValue
    }
    let pickerValue =
      viewModel.selectedTerminalModelByRuntime[viewModel.runtime]
      ?? catalog?.default
      ?? ""
    let customValue = viewModel.customTerminalModelByRuntime[viewModel.runtime] ?? ""
    let resolved = AgentsWindowView.effectiveModelId(
      pickerValue: pickerValue,
      customValue: customValue,
      catalogDefault: catalog?.default ?? ""
    )
    let effort = viewModel.selectedTerminalEffortByRuntime[viewModel.runtime]
    let success = await store.startAgentTui(
      runtime: viewModel.runtime,
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
      cols: startSize.cols
    )
    guard success, let startedTuiID = store.selectedAgentTui?.tuiId else {
      return
    }
    resetTerminalCreateForm(startedTuiID: startedTuiID)
  }

  private func resetTerminalCreateForm(startedTuiID: String) {
    viewModel.name = ""
    viewModel.prompt = ""
    viewModel.projectDir = ""
    viewModel.argvOverride = ""
    viewModel.inputText = ""
    viewModel.selectedPersona = nil
    viewModel.selectedRole = .worker
    viewModel.selection = .terminal(startedTuiID)
    focusedField = .input
  }
}
