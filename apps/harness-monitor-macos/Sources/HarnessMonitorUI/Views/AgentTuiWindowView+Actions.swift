import AppKit
import HarnessMonitorKit
import SwiftUI

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

  static func runtimeTitle(for tui: AgentTuiSnapshot) -> String {
    if let runtime = AgentTuiRuntime(rawValue: tui.runtime) {
      return runtime.title
    }

    if let suffix = tui.agentId.split(separator: "-").last, !suffix.isEmpty {
      return "Agent \(suffix)"
    }

    return tui.runtime.capitalized
  }

  static func initialSelection(
    displayState: AgentTuiDisplayState,
    selectedTuiID: String?
  ) -> AgentTuiSheetSelection {
    let orderedSessionIDs = displayState.sortedAgentTuis.map(\.tuiId)
    if let selectedTuiID, orderedSessionIDs.contains(selectedTuiID) {
      return .session(selectedTuiID)
    }
    if let fallbackTuiID = orderedSessionIDs.first {
      return .session(fallbackTuiID)
    }
    return .create
  }

  func selectCreateTab() {
    viewModel.selection = .create
  }

  func refresh() {
    viewModel.isSubmitting = true
    Task {
      if viewModel.selection.sessionID != nil,
        store.selectedAgentTui?.tuiId == viewModel.selection.sessionID
      {
        _ = await store.refreshSelectedAgentTui()
      } else {
        _ = await store.refreshSelectedAgentTuis()
      }
      reconcileSheetState(afterRefresh: false)
      syncTerminalSize()
      viewModel.isSubmitting = false
    }
  }

  func startTui() {
    viewModel.isSubmitting = true
    Task {
      let success = await store.startAgentTui(
        runtime: viewModel.runtime,
        name: viewModel.name,
        prompt: viewModel.prompt,
        projectDir: trimmedProjectDir,
        persona: viewModel.selectedPersona,
        argv: parsedArgvOverride,
        rows: viewModel.rows,
        cols: viewModel.cols
      )
      if success, let startedTuiID = store.selectedAgentTui?.tuiId {
        viewModel.name = ""
        viewModel.prompt = ""
        viewModel.projectDir = ""
        viewModel.argvOverride = ""
        viewModel.inputText = ""
        viewModel.selectedPersona = nil
        viewModel.selection = .session(startedTuiID)
        focusedField = .input
      }
      viewModel.isSubmitting = false
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
    Task {
      _ = await store.resizeAgentTui(tuiID: tui.tuiId, rows: viewModel.rows, cols: viewModel.cols)
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
    guard viewModel.selection.sessionID == tui.tuiId, tui.status.isActive else {
      return
    }
    guard
      let terminalSize = TerminalViewportSizing.terminalSize(
        for: viewportSize,
        fontScale: fontScale
      )
    else {
      return
    }
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
    viewModel.viewportResizeTask?.cancel()
    let tuiID = tui.tuiId
    viewModel.viewportResizeTask = Task { @MainActor in
      try? await Task.sleep(for: TerminalViewportSizing.debounce)
      guard !Task.isCancelled else {
        return
      }
      guard
        viewModel.selection.sessionID == tuiID,
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
        syncTerminalSize()
      }
    }
  }

  func cancelPendingViewportResize() {
    viewModel.viewportResizeTask?.cancel()
    viewModel.viewportResizeTask = nil
    viewModel.pendingViewportResizeTarget = nil
  }

  func syncTerminalSize() {
    guard let selectedSessionTui else {
      return
    }
    if viewModel.pendingViewportResizeTarget == selectedSessionTui.size {
      viewModel.pendingViewportResizeTarget = nil
    }
    if viewModel.rows != selectedSessionTui.size.rows {
      viewModel.rows = selectedSessionTui.size.rows
    }
    if viewModel.cols != selectedSessionTui.size.cols {
      viewModel.cols = selectedSessionTui.size.cols
    }
  }

  func reconcileSheetState(afterRefresh: Bool) {
    let preferredSelection = Self.initialSelection(
      displayState: viewModel.displayState,
      selectedTuiID: store.selectedAgentTui?.tuiId
    )

    if afterRefresh {
      applyProgrammaticSelection(preferredSelection)
      return
    }

    guard let selectedTuiID = viewModel.selection.sessionID else {
      return
    }

    guard store.selectedAgentTuis.contains(where: { $0.tuiId == selectedTuiID }) else {
      applyProgrammaticSelection(preferredSelection)
      return
    }

    syncTerminalSize()
  }

  func applyProgrammaticSelection(_ nextSelection: AgentTuiSheetSelection) {
    guard viewModel.selection != nextSelection else {
      if nextSelection.sessionID != nil {
        syncTerminalSize()
      }
      return
    }
    viewModel.suppressHistoryRecording = true
    viewModel.selection = nextSelection
    if nextSelection.sessionID != nil {
      syncTerminalSize()
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
    viewModel.windowNavigation.canGoBack = !viewModel.navigationBackStack.isEmpty
    viewModel.windowNavigation.canGoForward = !viewModel.navigationForwardStack.isEmpty
  }
}
