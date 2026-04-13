import AppKit
import HarnessMonitorKit
import SwiftUI

extension AgentTuiWindowView {
  func refreshDisplayState() {
    let nextState = AgentTuiDisplayState(store: store)
    guard displayState != nextState else {
      return
    }
    displayState = nextState
  }

  func resolvedTitle(for tui: AgentTuiSnapshot) -> String {
    displayState.sessionTitlesByID[tui.tuiId] ?? resolvedRuntimeTitle(for: tui)
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
    selection = .create
  }

  func refresh() {
    isSubmitting = true
    Task {
      if selection.sessionID != nil,
        store.selectedAgentTui?.tuiId == selection.sessionID
      {
        _ = await store.refreshSelectedAgentTui()
      } else {
        _ = await store.refreshSelectedAgentTuis()
      }
      reconcileSheetState(afterRefresh: false)
      syncTerminalSize()
      isSubmitting = false
    }
  }

  func startTui() {
    isSubmitting = true
    Task {
      let success = await store.startAgentTui(
        runtime: runtime,
        name: name,
        prompt: prompt,
        projectDir: trimmedProjectDir,
        persona: selectedPersona,
        argv: parsedArgvOverride,
        rows: rows,
        cols: cols
      )
      if success, let startedTuiID = store.selectedAgentTui?.tuiId {
        name = ""
        prompt = ""
        projectDir = ""
        argvOverride = ""
        inputText = ""
        selectedPersona = nil
        selection = .session(startedTuiID)
        focusedField = .input
      }
      isSubmitting = false
    }
  }

  func sendInput(to tui: AgentTuiSnapshot) {
    let payload: AgentTuiInput =
      switch inputMode {
      case .text:
        .text(trimmedInput)
      case .paste:
        .paste(trimmedInput)
      }

    isSubmitting = true
    Task {
      let success = await store.sendAgentTuiInput(tuiID: tui.tuiId, input: payload)
      if success {
        inputText = ""
      }
      isSubmitting = false
    }
  }

  func sendKey(_ key: AgentTuiKey, to tui: AgentTuiSnapshot) {
    isSubmitting = true
    Task {
      _ = await store.sendAgentTuiInput(tuiID: tui.tuiId, input: .key(key))
      isSubmitting = false
    }
  }

  func sendControl(_ key: Character, to tui: AgentTuiSnapshot) {
    isSubmitting = true
    Task {
      _ = await store.sendAgentTuiInput(tuiID: tui.tuiId, input: .control(key))
      isSubmitting = false
    }
  }

  func resizeTui(_ tui: AgentTuiSnapshot) {
    isSubmitting = true
    Task {
      _ = await store.resizeAgentTui(tuiID: tui.tuiId, rows: rows, cols: cols)
      isSubmitting = false
    }
  }

  func stopTui(_ tui: AgentTuiSnapshot) {
    isSubmitting = true
    Task {
      _ = await store.stopAgentTui(tuiID: tui.tuiId)
      isSubmitting = false
    }
  }

  func revealTranscript(_ tui: AgentTuiSnapshot) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tui.transcriptPath)])
  }

  func updateViewportGeometry(_ viewportSize: CGSize, for tui: AgentTuiSnapshot) {
    guard selection.sessionID == tui.tuiId, tui.status.isActive else {
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
    if rows != terminalSize.rows {
      rows = terminalSize.rows
    }
    if cols != terminalSize.cols {
      cols = terminalSize.cols
    }
    guard terminalSize != tui.size, terminalSize != pendingViewportResizeTarget else {
      return
    }

    pendingViewportResizeTarget = terminalSize
    viewportResizeTask?.cancel()
    let tuiID = tui.tuiId
    viewportResizeTask = Task { @MainActor in
      try? await Task.sleep(for: TerminalViewportSizing.debounce)
      guard !Task.isCancelled else {
        return
      }
      guard
        selection.sessionID == tuiID,
        selectedSessionTui?.status.isActive == true
      else {
        if pendingViewportResizeTarget == terminalSize {
          pendingViewportResizeTarget = nil
        }
        return
      }

      let resized = await store.resizeAgentTui(
        tuiID: tuiID,
        rows: terminalSize.rows,
        cols: terminalSize.cols,
        feedback: .silent
      )
      guard pendingViewportResizeTarget == terminalSize else {
        return
      }
      pendingViewportResizeTarget = nil
      if !resized {
        syncTerminalSize()
      }
    }
  }

  func cancelPendingViewportResize() {
    viewportResizeTask?.cancel()
    viewportResizeTask = nil
    pendingViewportResizeTarget = nil
  }

  func syncTerminalSize() {
    guard let selectedSessionTui else {
      return
    }
    if pendingViewportResizeTarget == selectedSessionTui.size {
      pendingViewportResizeTarget = nil
    }
    if rows != selectedSessionTui.size.rows {
      rows = selectedSessionTui.size.rows
    }
    if cols != selectedSessionTui.size.cols {
      cols = selectedSessionTui.size.cols
    }
  }

  func reconcileSheetState(afterRefresh: Bool) {
    let preferredSelection = Self.initialSelection(
      displayState: displayState,
      selectedTuiID: store.selectedAgentTui?.tuiId
    )

    if afterRefresh {
      applyProgrammaticSelection(preferredSelection)
      return
    }

    guard let selectedTuiID = selection.sessionID else {
      return
    }

    guard store.selectedAgentTuis.contains(where: { $0.tuiId == selectedTuiID }) else {
      applyProgrammaticSelection(preferredSelection)
      return
    }

    syncTerminalSize()
  }

  func applyProgrammaticSelection(_ nextSelection: AgentTuiSheetSelection) {
    guard selection != nextSelection else {
      if nextSelection.sessionID != nil {
        syncTerminalSize()
      }
      return
    }
    suppressHistoryRecording = true
    selection = nextSelection
    if nextSelection.sessionID != nil {
      syncTerminalSize()
    }
  }

  func navigateHistoryBack() {
    guard !navigationBackStack.isEmpty else { return }
    let destination = navigationBackStack.removeLast()
    navigationForwardStack.append(selection)
    suppressHistoryRecording = true
    selection = destination
    updateNavigationState()
  }

  func navigateHistoryForward() {
    guard !navigationForwardStack.isEmpty else { return }
    let destination = navigationForwardStack.removeLast()
    navigationBackStack.append(selection)
    suppressHistoryRecording = true
    selection = destination
    updateNavigationState()
  }

  func updateNavigationState() {
    windowNavigation.canGoBack = !navigationBackStack.isEmpty
    windowNavigation.canGoForward = !navigationForwardStack.isEmpty
  }
}
