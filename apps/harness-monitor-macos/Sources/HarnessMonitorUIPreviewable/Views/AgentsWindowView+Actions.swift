import AppKit
import HarnessMonitorKit
import SwiftUI

extension AgentsWindowView {
  func managedDisplayState() -> AgentTuiDisplayState {
    AgentTuiDisplayState(
      store: store,
      includeActiveAgentTuis: viewModel.hasFreshManagedAgentTuis,
      includeActiveCodexRuns: viewModel.hasFreshManagedCodexRuns
    )
  }

  func updateDetailColumnGeometry(_ size: CGSize) {
    viewModel.lastDetailColumnSize = size
  }

  func syncTerminalResizeControls(to size: AgentTuiSize) {
    if viewModel.rows != size.rows {
      viewModel.rows = size.rows
    }
    if viewModel.cols != size.cols {
      viewModel.cols = size.cols
    }
  }

  static func initialSelection(
    displayState: AgentTuiDisplayState,
    selectedTerminalID: String?,
    selectedCodexRunID: String?
  ) -> WorkspaceSelection {
    if let selectedTerminalID,
      let selectedTerminal = displayState.sortedAgentTuis.first(
        where: { $0.tuiId == selectedTerminalID }
      )
    {
      return .terminal(sessionID: selectedTerminal.sessionId, terminalID: selectedTerminalID)
    }
    if let selectedCodexRunID,
      let selectedRun = displayState.sortedCodexRuns.first(
        where: { $0.runId == selectedCodexRunID }
      )
    {
      return .codex(sessionID: selectedRun.sessionId, runID: selectedCodexRunID)
    }
    if let fallbackTui = displayState.sortedAgentTuis.first {
      return .terminal(sessionID: fallbackTui.sessionId, terminalID: fallbackTui.tuiId)
    }
    if let fallbackRun = displayState.sortedCodexRuns.first {
      return .codex(sessionID: fallbackRun.sessionId, runID: fallbackRun.runId)
    }
    return .create
  }
  func selectCreateTab() { viewModel.selection = .create }

  func refreshDisplayState() {
    let displayState = managedDisplayState()
    guard viewModel.displayState != displayState else {
      return
    }
    viewModel.displayState = displayState
  }

  func refresh() {
    viewModel.isSubmitting = true
    Task {
      await flushPendingKeySequenceIfNeeded()
      switch viewModel.selection {
      case .create,
        .decisions,
        .decision,
        .agent,
        .task:
        applyManagedSelectionFreshness(await refreshManagedSelections())
      case .terminal(_, let tuiID):
        if store.selectedAgentTui?.tuiId == tuiID {
          let refreshed = await store.refreshSelectedAgentTui()
          if refreshed {
            viewModel.hasFreshManagedAgentTuis = true
          }
        } else {
          let refreshed = await store.refreshSelectedAgentTuis()
          if refreshed {
            viewModel.hasFreshManagedAgentTuis = true
          }
        }
      case .codex(_, let runID):
        if store.selectedCodexRun?.runId == runID {
          let refreshed = await store.refreshSelectedCodexRun()
          if refreshed {
            viewModel.hasFreshManagedCodexRuns = true
          }
        } else {
          let refreshed = await store.refreshSelectedCodexRuns()
          if refreshed {
            viewModel.hasFreshManagedCodexRuns = true
          }
        }
      }
      refreshDisplayState()
      reconcileSheetState(afterRefresh: false)
      enforceExpectedSize()
      viewModel.isSubmitting = false
    }
  }
  func startTui() {
    viewModel.isSubmitting = true
    viewModel.startTuiAttemptCount += 1
    viewModel.startTuiPhase = "scheduled"
    Task {
      switch viewModel.createMode {
      case .terminal:
        viewModel.startTuiPhase = "terminal"
        await startTerminalAgent()
      case .codex:
        viewModel.startTuiPhase = "codex"
        viewModel.codexStartAttemptCount += 1
        viewModel.codexStartResult = "started"
        let catalog = viewModel.availableRuntimeModels.first { $0.runtime == "codex" }
        let pickerValue = viewModel.selectedCodexModel ?? catalog?.default ?? ""
        let customValue = viewModel.customCodexModel ?? ""
        let resolved = AgentsWindowView.effectiveModelId(
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
          viewModel.codexStartResult = "run"
          viewModel.codexPrompt = ""
          viewModel.codexContext = ""
          viewModel.selection = .codex(sessionID: startedRun.sessionId, runID: startedRun.runId)
        } else {
          viewModel.codexStartResult = "nil"
        }
      }
      viewModel.startTuiPhase = "done"
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
      await flushPendingKeySequenceIfNeeded()
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
    queueKeyInput(.key(key), glyph: key.glyph, to: tui.tuiId)
  }
  func sendControl(_ key: Character, to tui: AgentTuiSnapshot) {
    queueKeyInput(.control(key), glyph: "⌃\(String(key).uppercased())", to: tui.tuiId)
  }
  func resizeTui(_ tui: AgentTuiSnapshot) {
    viewModel.isSubmitting = true
    cancelPendingViewportResize()
    let target = AgentTuiSize(rows: viewModel.rows, cols: viewModel.cols)
    viewModel.expectedSize = target
    Task {
      await flushPendingKeySequenceIfNeeded()
      _ = await store.resizeAgentTui(tuiID: tui.tuiId, rows: target.rows, cols: target.cols)
      viewModel.isSubmitting = false
    }
  }
  func stopTui(_ tui: AgentTuiSnapshot) {
    viewModel.isSubmitting = true
    let tuiID = tui.tuiId
    let stopper = StoreBackedAgentTuiStopper(store: store)
    Task {
      await flushPendingKeySequenceIfNeeded()
      await performGracefulStop(tuiID: tuiID, stopper: stopper)
      viewModel.isSubmitting = false
    }
  }
  func queueKeyInput(_ input: AgentTuiInput, glyph: String, to tuiID: String) {
    let store = store
    let viewModel = viewModel
    @MainActor
    func sendRequest(_ targetTuiID: String, _ request: AgentTuiInputRequest) async {
      guard
        let targetTui = store.selectedAgentTuis.first(where: { $0.tuiId == targetTuiID }),
        targetTui.status.isActive
      else {
        return
      }
      viewModel.isSubmitting = true
      defer { viewModel.isSubmitting = false }
      _ = await store.sendAgentTuiInput(
        tuiID: targetTui.tuiId,
        request: request,
        showSuccessFeedback: false
      )
    }
    let result = viewModel.keySequenceBuffer.enqueue(
      input: input,
      glyph: glyph,
      tuiID: tuiID
    ) { targetTuiID, request in
      await sendRequest(targetTuiID, request)
    }
    guard case .sendImmediately(let request) = result else {
      return
    }
    Task {
      await sendRequest(tuiID, request)
    }
  }
  func flushPendingKeySequenceIfNeeded() async {
    await viewModel.keySequenceBuffer.flush()
  }
  func dropPendingKeySequence() {
    viewModel.keySequenceBuffer.drop()
  }
  func revealTranscript(_ tui: AgentTuiSnapshot) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tui.transcriptPath)])
  }
  func updateViewportGeometry(_ viewportSize: CGSize, for tui: AgentTuiSnapshot) {
    guard viewModel.selection.terminalID == tui.tuiId, tui.status.isActive else {
      return
    }
    viewModel.lastMeasuredViewportPoints = viewportSize
    guard
      let measuredTerminalSize = TerminalViewportSizing.terminalSize(
        for: viewportSize,
        fontScale: fontScale
      )
    else {
      viewModel.lastMeasuredViewportTerminalSize = nil
      return
    }
    viewModel.lastMeasuredViewportTerminalSize = measuredTerminalSize
    let resizeBaseline = TerminalViewportSizing.automaticResizeBaseline(
      serverSize: tui.size,
      pendingTarget: viewModel.pendingViewportResizeTarget,
      expectedSize: viewModel.expectedSize
    )
    let terminalSize = TerminalViewportSizing.stabilizedAutomaticSize(
      measured: measuredTerminalSize,
      baseline: resizeBaseline
    )
    viewModel.lastMeasuredViewportSize = terminalSize
    syncTerminalResizeControls(to: terminalSize)
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
      await flushPendingKeySequenceIfNeeded()
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
      await flushPendingKeySequenceIfNeeded()
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
    guard !afterRefresh else {
      applyProgrammaticSelection(preferredSelection)
      return
    }

    let keepsCurrentSelection =
      switch viewModel.selection {
      case .create, .decisions, .decision:
        true
      case .terminal(_, let selectedTuiID):
        store.selectedAgentTuis.contains { $0.tuiId == selectedTuiID }
      case .codex(_, let selectedRunID):
        store.selectedCodexRuns.contains { $0.runId == selectedRunID }
      case .agent(_, let selectedAgentID):
        store.selectedSession?.agents.contains { $0.agentId == selectedAgentID } ?? false
      case .task(_, let selectedTaskID):
        store.selectedSession?.tasks.contains { $0.taskId == selectedTaskID } ?? false
      }

    guard keepsCurrentSelection else {
      applyProgrammaticSelection(preferredSelection)
      return
    }

    if case .terminal = viewModel.selection {
      enforceExpectedSize()
    }
  }
}
