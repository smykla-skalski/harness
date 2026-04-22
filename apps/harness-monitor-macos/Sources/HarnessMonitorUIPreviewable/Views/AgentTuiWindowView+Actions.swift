import AppKit
import HarnessMonitorKit
import SwiftUI

extension AgentTuiWindowView {
  static func initialSelection(
    displayState: AgentTuiDisplayState,
    selectedTerminalID: String?,
    selectedCodexRunID: String?
  ) -> AgentTuiSheetSelection {
    let orderedSessionIDs = displayState.sortedAgentTuis.map(\.tuiId)
    let orderedRunIDs = displayState.sortedCodexRuns.map(\.runId)
    if let selectedTerminalID, orderedSessionIDs.contains(selectedTerminalID) {
      return .terminal(selectedTerminalID)
    }
    if let selectedCodexRunID, orderedRunIDs.contains(selectedCodexRunID) {
      return .codex(selectedCodexRunID)
    }
    if let fallbackTuiID = orderedSessionIDs.first {
      return .terminal(fallbackTuiID)
    }
    if let fallbackRunID = orderedRunIDs.first {
      return .codex(fallbackRunID)
    }
    return .create
  }

  func selectCreateTab() {
    viewModel.selection = .create
  }

  func refresh() {
    viewModel.isSubmitting = true
    Task {
      switch viewModel.selection {
      case .create:
        async let tuiRefresh = store.refreshSelectedAgentTuis()
        async let codexRefresh = store.refreshSelectedCodexRuns()
        _ = await tuiRefresh
        _ = await codexRefresh
      case .terminal(let tuiID):
        if store.selectedAgentTui?.tuiId == tuiID {
          _ = await store.refreshSelectedAgentTui()
        } else {
          _ = await store.refreshSelectedAgentTuis()
        }
      case .codex(let runID):
        if store.selectedCodexRun?.runId == runID {
          _ = await store.refreshSelectedCodexRun()
        } else {
          _ = await store.refreshSelectedCodexRuns()
        }
      }
      reconcileSheetState(afterRefresh: false)
      enforceExpectedSize()
      viewModel.isSubmitting = false
    }
  }

  func startTui() {
    viewModel.isSubmitting = true
    Task {
      switch viewModel.createMode {
      case .terminal:
        let startSize = AgentTuiSize(rows: viewModel.rows, cols: viewModel.cols)
        viewModel.expectedSize = startSize
        let catalog = viewModel.availableRuntimeModels.first {
          $0.runtime == viewModel.runtime.rawValue
        }
        let pickerValue =
          viewModel.selectedTerminalModelByRuntime[viewModel.runtime]
          ?? catalog?.default
          ?? ""
        let customValue = viewModel.customTerminalModelByRuntime[viewModel.runtime] ?? ""
        let resolved = AgentTuiWindowView.effectiveModelId(
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
        if success, let startedTuiID = store.selectedAgentTui?.tuiId {
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
      case .codex:
        let catalog = viewModel.availableRuntimeModels.first { $0.runtime == "codex" }
        let pickerValue = viewModel.selectedCodexModel ?? catalog?.default ?? ""
        let customValue = viewModel.customCodexModel ?? ""
        let resolved = AgentTuiWindowView.effectiveModelId(
          pickerValue: pickerValue,
          customValue: customValue,
          catalogDefault: catalog?.default ?? ""
        )
        let startedRun = await store.startCodexRunSnapshot(
          prompt: viewModel.codexPrompt,
          mode: viewModel.codexMode,
          model: resolved.id,
          effort: viewModel.selectedCodexEffort,
          allowCustomModel: resolved.allowCustom
        )
        if let startedRun {
          viewModel.codexPrompt = ""
          viewModel.codexContext = ""
          viewModel.selection = .codex(startedRun.runId)
        }
      }
      viewModel.isSubmitting = false
    }
  }

  func steerCodexRun(_ run: CodexRunSnapshot) {
    viewModel.isSubmitting = true
    Task {
      let success = await store.steerCodexRun(runID: run.runId, prompt: viewModel.codexContext)
      if success {
        viewModel.codexContext = ""
      }
      viewModel.isSubmitting = false
    }
  }

  func interruptCodexRun(_ run: CodexRunSnapshot) {
    viewModel.isSubmitting = true
    Task {
      _ = await store.interruptCodexRun(runID: run.runId)
      viewModel.isSubmitting = false
    }
  }

  func resolveCodexApproval(
    _ approval: CodexApprovalRequest,
    run: CodexRunSnapshot,
    decision: CodexApprovalDecision
  ) {
    viewModel.resolvingCodexApprovalID = approval.approvalId
    Task {
      _ = await store.resolveCodexApproval(
        runID: run.runId,
        approvalID: approval.approvalId,
        decision: decision
      )
      viewModel.resolvingCodexApprovalID = nil
    }
  }

  func sendInput(to tui: AgentTuiSnapshot) {
    let payload: AgentTuiInput =
      switch viewModel.inputMode {
      case .text:
        .text(trimmedInput)
      case .paste:
        .paste(trimmedInput)
      }

    viewModel.isSubmitting = true
    Task {
      let success = await store.sendAgentTuiInput(tuiID: tui.tuiId, input: payload)
      if success {
        viewModel.inputText = ""
        if submitSendsEnter {
          _ = await store.sendAgentTuiInput(
            tuiID: tui.tuiId,
            input: .key(.enter),
            showSuccessFeedback: false
          )
        }
      }
      viewModel.isSubmitting = false
    }
  }

  func sendKey(_ key: AgentTuiKey, to tui: AgentTuiSnapshot) {
    viewModel.isSubmitting = true
    Task {
      _ = await store.sendAgentTuiInput(tuiID: tui.tuiId, input: .key(key))
      viewModel.isSubmitting = false
    }
  }

  func sendControl(_ key: Character, to tui: AgentTuiSnapshot) {
    viewModel.isSubmitting = true
    Task {
      _ = await store.sendAgentTuiInput(tuiID: tui.tuiId, input: .control(key))
      viewModel.isSubmitting = false
    }
  }

  func resizeTui(_ tui: AgentTuiSnapshot) {
    viewModel.isSubmitting = true
    cancelPendingViewportResize()
    let target = AgentTuiSize(rows: viewModel.rows, cols: viewModel.cols)
    viewModel.expectedSize = target
    Task {
      _ = await store.resizeAgentTui(tuiID: tui.tuiId, rows: target.rows, cols: target.cols)
      viewModel.isSubmitting = false
    }
  }

  func stopTui(_ tui: AgentTuiSnapshot) {
    viewModel.isSubmitting = true
    Task {
      _ = await store.stopAgentTui(tuiID: tui.tuiId)
      viewModel.isSubmitting = false
    }
  }

  func revealTranscript(_ tui: AgentTuiSnapshot) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tui.transcriptPath)])
  }

  func updateViewportGeometry(_ viewportSize: CGSize, for tui: AgentTuiSnapshot) {
    guard viewModel.selection.terminalID == tui.tuiId, tui.status.isActive else {
      return
    }
    guard
      let measuredTerminalSize = TerminalViewportSizing.terminalSize(
        for: viewportSize,
        fontScale: fontScale
      )
    else {
      return
    }
    let resizeBaseline = viewModel.pendingViewportResizeTarget ?? tui.size
    let terminalSize = TerminalViewportSizing.stabilizedAutomaticSize(
      measured: measuredTerminalSize,
      baseline: resizeBaseline
    )
    if viewModel.rows != terminalSize.rows {
      viewModel.rows = terminalSize.rows
    }
    if viewModel.cols != terminalSize.cols {
      viewModel.cols = terminalSize.cols
    }
    guard terminalSize != tui.size,
      terminalSize != viewModel.pendingViewportResizeTarget
    else {
      return
    }

    viewModel.pendingViewportResizeTarget = terminalSize
    viewModel.expectedSize = terminalSize
    viewModel.viewportResizeTask?.cancel()
    let tuiID = tui.tuiId
    viewModel.viewportResizeTask = Task { @MainActor in
      try? await Task.sleep(for: TerminalViewportSizing.debounce)
      guard !Task.isCancelled else {
        return
      }
      guard
        viewModel.selection.terminalID == tuiID,
        selectedSessionTui?.status.isActive == true
      else {
        if viewModel.pendingViewportResizeTarget == terminalSize {
          viewModel.pendingViewportResizeTarget = nil
        }
        return
      }

      let resized = await store.resizeAgentTui(
        tuiID: tuiID,
        rows: terminalSize.rows,
        cols: terminalSize.cols,
        feedback: .silent
      )
      guard viewModel.pendingViewportResizeTarget == terminalSize else {
        return
      }
      viewModel.pendingViewportResizeTarget = nil
      if !resized {
        enforceExpectedSize()
      }
    }
  }

  func cancelPendingViewportResize() {
    viewModel.viewportResizeTask?.cancel()
    viewModel.viewportResizeTask = nil
    viewModel.pendingViewportResizeTarget = nil
  }

  func enforceExpectedSize() {
    guard let expected = viewModel.expectedSize,
      let serverSize = selectedSessionTui?.size,
      let tuiID = selectedSessionTui?.tuiId,
      expected != serverSize,
      selectedSessionTui?.status.isActive == true
    else {
      return
    }
    Task {
      _ = await store.resizeAgentTui(
        tuiID: tuiID,
        rows: expected.rows,
        cols: expected.cols,
        feedback: .silent
      )
    }
  }

  func reconcileSheetState(afterRefresh: Bool) {
    let preferredSelection = Self.initialSelection(
      displayState: displayState,
      selectedTerminalID: store.selectedAgentTui?.tuiId,
      selectedCodexRunID: store.selectedCodexRun?.runId
    )

    if afterRefresh {
      applyProgrammaticSelection(preferredSelection)
      return
    }

    switch viewModel.selection {
    case .create:
      break
    case .terminal(let selectedTuiID):
      guard store.selectedAgentTuis.contains(where: { $0.tuiId == selectedTuiID }) else {
        applyProgrammaticSelection(preferredSelection)
        return
      }
      enforceExpectedSize()
    case .codex(let selectedRunID):
      guard store.selectedCodexRuns.contains(where: { $0.runId == selectedRunID }) else {
        applyProgrammaticSelection(preferredSelection)
        return
      }
    }
  }

  func applyProgrammaticSelection(_ nextSelection: AgentTuiSheetSelection) {
    guard viewModel.selection != nextSelection else {
      if nextSelection.terminalID != nil {
        enforceExpectedSize()
      }
      return
    }
    viewModel.suppressHistoryRecording = true
    viewModel.selection = nextSelection
    if nextSelection.terminalID != nil {
      enforceExpectedSize()
    }
  }

  func navigateHistoryBack() {
    guard !viewModel.navigationBackStack.isEmpty else { return }
    let destination = viewModel.navigationBackStack.removeLast()
    viewModel.navigationForwardStack.append(viewModel.selection)
    viewModel.suppressHistoryRecording = true
    viewModel.selection = destination
    updateNavigationState()
  }

  func navigateHistoryForward() {
    guard !viewModel.navigationForwardStack.isEmpty else { return }
    let destination = viewModel.navigationForwardStack.removeLast()
    viewModel.navigationBackStack.append(viewModel.selection)
    viewModel.suppressHistoryRecording = true
    viewModel.selection = destination
    updateNavigationState()
  }

  func updateNavigationState() {
    let canGoBack = !viewModel.navigationBackStack.isEmpty
    let canGoForward = !viewModel.navigationForwardStack.isEmpty
    guard
      viewModel.windowNavigation.canGoBack != canGoBack
        || viewModel.windowNavigation.canGoForward != canGoForward
    else {
      return
    }
    viewModel.windowNavigation = viewModel.windowNavigation.updating(
      canGoBack: canGoBack,
      canGoForward: canGoForward
    )
    navigationBridge.update(viewModel.windowNavigation)
  }
}
