import AppKit
import HarnessMonitorKit
import SwiftUI

struct CodexFlowSheetView: View {
  let store: HarnessMonitorStore
  @Environment(\.dismiss)
  private var dismiss
  @State private var prompt = ""
  @State private var context = ""
  @State private var mode: CodexRunMode = .report
  @State private var isSubmitting = false
  @State private var resolvingApprovalID: String?
  @FocusState private var focusedField: Field?

  private enum Field: Hashable {
    case prompt
    case context
  }

  private var selectedRun: CodexRunSnapshot? {
    store.selectedCodexRun
  }

  private var codexBridgeState: HarnessMonitorStore.HostBridgeCapabilityState {
    store.hostBridgeCapabilityState(for: "codex")
  }

  private var codexBridgeCommand: String {
    store.hostBridgeStartCommand(for: "codex")
  }

  private var hostBridge: HostBridgeManifest {
    store.daemonStatus?.manifest?.hostBridge ?? HostBridgeManifest()
  }

  private var codexBridgeCapabilityPresent: Bool {
    hostBridge.capabilities["codex"] != nil
  }

  private var canSubmit: Bool {
    !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSubmitting
  }

  private var canSteer: Bool {
    guard let selectedRun else { return false }
    return selectedRun.status.isActive
      && !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !isSubmitting
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
          if store.codexUnavailable {
            codexUnavailableBanner
          }
          promptSection
          if let selectedRun {
            runSection(selectedRun)
          } else {
            Text("No Codex runs yet.")
              .scaledFont(.subheadline)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          }
        }
        .padding(HarnessMonitorTheme.spacingLG)
      }
      Divider()
      footer
    }
    .frame(minWidth: 520, idealWidth: 620, minHeight: 520)
    .task { await store.refreshSelectedCodexRuns() }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.codexFlowSheet)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text("Codex Flow")
        .scaledFont(.system(.title3, design: .rounded, weight: .bold))
      Text(store.selectedSession?.session.title ?? "Selected session")
        .scaledFont(.subheadline)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var promptSection: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack {
        Text("Prompt")
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Spacer()
        HarnessVoiceInputButton(
          store: store,
          text: $prompt,
          label: "Dictate Codex prompt",
          routeTarget: { .codexPrompt },
          accessibilityIdentifier: HarnessMonitorAccessibility.codexFlowPromptVoiceButton
        )
      }
      TextField("Ask Codex to investigate or patch this session", text: $prompt, axis: .vertical)
        .harnessNativeFormControl()
        .lineLimit(4, reservesSpace: true)
        .focused($focusedField, equals: .prompt)
        .accessibilityIdentifier(HarnessMonitorAccessibility.codexFlowPromptField)
      Picker("Mode", selection: $mode) {
        ForEach(CodexRunMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier(HarnessMonitorAccessibility.codexFlowModePicker)
    }
  }

  private func runSection(_ run: CodexRunSnapshot) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      runHeader(run)
      if let finalMessage = run.finalMessage, !finalMessage.isEmpty {
        codexTextSection(title: "Final", text: finalMessage)
      } else if let latestSummary = run.latestSummary, !latestSummary.isEmpty {
        codexTextSection(title: "Latest", text: latestSummary)
      }
      if let error = run.error, !error.isEmpty {
        codexTextSection(title: "Error", text: error)
          .foregroundStyle(HarnessMonitorTheme.danger)
      }
      if !run.pendingApprovals.isEmpty {
        approvalsSection(run)
      }
      if run.status.isActive {
        contextSection(run)
      }
    }
  }

  private func runHeader(_ run: CodexRunSnapshot) -> some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Text(run.status.title)
          .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
        Text(run.mode.title)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      Spacer()
      if run.status.isActive {
        Button("Interrupt") {
          interrupt(run)
        }
        .harnessActionButtonStyle(variant: .bordered, tint: nil)
        .disabled(isSubmitting)
        .accessibilityIdentifier(HarnessMonitorAccessibility.codexFlowInterruptButton)
      }
    }
  }

  private func codexTextSection(title: String, text: String) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(title)
        .scaledFont(.caption.bold())
      Text(text)
        .scaledFont(.body)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func approvalsSection(_ run: CodexRunSnapshot) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      Text("Approvals")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      ForEach(run.pendingApprovals) { approval in
        approvalRow(approval, runID: run.runId)
      }
    }
  }

  private func approvalRow(_ approval: CodexApprovalRequest, runID: String) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(approval.title)
        .scaledFont(.headline)
      Text(approval.detail)
        .scaledFont(.subheadline)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .textSelection(.enabled)
      HStack {
        approvalButton("Approve", approval: approval, runID: runID, decision: .accept)
        approvalButton(
          "Allow Session", approval: approval, runID: runID, decision: .acceptForSession)
        approvalButton("Decline", approval: approval, runID: runID, decision: .decline)
        Spacer()
        approvalButton("Cancel", approval: approval, runID: runID, decision: .cancel)
      }
    }
    .padding(.vertical, HarnessMonitorTheme.spacingXS)
  }

  private func approvalButton(
    _ title: String,
    approval: CodexApprovalRequest,
    runID: String,
    decision: CodexApprovalDecision
  ) -> some View {
    Button(title) {
      resolve(approval, runID: runID, decision: decision)
    }
    .disabled(resolvingApprovalID != nil || isSubmitting)
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.codexApprovalButton(
        approval.approvalId, decision: decision.rawValue)
    )
  }

  private func contextSection(_ run: CodexRunSnapshot) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack {
        Text("New Context")
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Spacer()
        HarnessVoiceInputButton(
          store: store,
          text: $context,
          label: "Dictate Codex context",
          routeTarget: { .codexContext(runID: run.runId) },
          accessibilityIdentifier: HarnessMonitorAccessibility.codexFlowContextVoiceButton
        )
      }
      TextField("Add context to the active turn", text: $context, axis: .vertical)
        .harnessNativeFormControl()
        .lineLimit(3, reservesSpace: true)
        .focused($focusedField, equals: .context)
        .accessibilityIdentifier(HarnessMonitorAccessibility.codexFlowContextField)
      Button("Send Context") {
        steer(run)
      }
      .harnessActionButtonStyle(variant: .bordered, tint: nil)
      .disabled(!canSteer)
      .accessibilityIdentifier(HarnessMonitorAccessibility.codexFlowSteerButton)
    }
  }

  private var footer: some View {
    HStack {
      Button("Close") {
        dismiss()
      }
      .keyboardShortcut(.cancelAction)
      .accessibilityIdentifier(HarnessMonitorAccessibility.codexFlowCancelButton)
      Spacer()
      Button("Start Codex Run") {
        submit()
      }
      .keyboardShortcut(.defaultAction)
      .harnessActionButtonStyle(variant: .prominent, tint: nil)
      .disabled(!canSubmit)
      .accessibilityIdentifier(HarnessMonitorAccessibility.codexFlowSubmitButton)
    }
    .padding(HarnessMonitorTheme.spacingLG)
  }

  private func submit() {
    isSubmitting = true
    Task {
      let success = await store.startCodexRun(prompt: prompt, mode: mode)
      if success {
        prompt = ""
        focusedField = .context
      }
      isSubmitting = false
    }
  }

  private func steer(_ run: CodexRunSnapshot) {
    isSubmitting = true
    Task {
      let success = await store.steerCodexRun(runID: run.runId, prompt: context)
      if success {
        context = ""
      }
      isSubmitting = false
    }
  }

  private func interrupt(_ run: CodexRunSnapshot) {
    isSubmitting = true
    Task {
      _ = await store.interruptCodexRun(runID: run.runId)
      isSubmitting = false
    }
  }

  private func resolve(
    _ approval: CodexApprovalRequest,
    runID: String,
    decision: CodexApprovalDecision
  ) {
    resolvingApprovalID = approval.approvalId
    Task {
      _ = await store.resolveCodexApproval(
        runID: runID,
        approvalID: approval.approvalId,
        decision: decision
      )
      resolvingApprovalID = nil
    }
  }

  private var codexUnavailableBanner: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Label(codexBridgeTitle, systemImage: "exclamationmark.triangle")
        .scaledFont(.headline)
        .foregroundStyle(.orange)
      Text(codexBridgeMessage)
        .scaledFont(.subheadline)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      if codexBridgeState == .excluded && hostBridge.running {
        Button("Enable now") {
          Task {
            _ = await store.setHostBridgeCapability("codex", enabled: true)
          }
        }
        .harnessActionButtonStyle(variant: .prominent, tint: nil)
        .disabled(store.isDaemonActionInFlight || isSubmitting)
      }
      CopyableCommandBox(
        command: codexBridgeCommand,
        accessibilityIdentifier: HarnessMonitorAccessibility.codexFlowCopyCommandButton
      )
    }
    .padding(HarnessMonitorTheme.spacingMD)
    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.codexFlowRecoveryBanner)
  }

  private var codexBridgeTitle: String {
    switch codexBridgeState {
    case .excluded:
      "Codex is excluded from the host bridge"
    case .unavailable:
      "Codex host bridge is not running"
    case .ready:
      "Codex host bridge ready"
    }
  }

  private var codexBridgeMessage: String {
    switch codexBridgeState {
    case .excluded:
      "The shared host bridge is running without the Codex capability. Enable it now or run this in a terminal:"
    case .unavailable:
      if hostBridge.running && codexBridgeCapabilityPresent {
        "The shared host bridge is running, but the Codex capability is unavailable. Re-enable it or run this in a terminal:"
      } else {
        "Harness Monitor runs sandboxed and cannot start Codex directly. Run this in a terminal:"
      }
    case .ready:
      ""
    }
  }
}

struct AgentTuiSheetView: View {
  let store: HarnessMonitorStore
  @Environment(\.dismiss)
  private var dismiss
  @State private var runtime: AgentTuiRuntime = .copilot
  @State private var name = ""
  @State private var prompt = ""
  @State private var inputText = ""
  @State private var inputMode: AgentTuiInputMode = .text
  @State private var rows = 32
  @State private var cols = 120
  @State private var isSubmitting = false
  @FocusState private var focusedField: Field?

  private enum Field: Hashable {
    case prompt
    case input
  }

  private enum AgentTuiInputMode: String, CaseIterable, Identifiable {
    case text
    case paste

    var id: String { rawValue }

    var title: String {
      switch self {
      case .text:
        "Type"
      case .paste:
        "Paste"
      }
    }
  }

  private let commonKeys: [AgentTuiKey] = [
    .enter, .tab, .escape, .backspace, .arrowUp, .arrowDown, .arrowLeft, .arrowRight,
  ]

  private var selectedTui: AgentTuiSnapshot? {
    store.selectedAgentTui
  }

  private var agentTuiBridgeState: HarnessMonitorStore.HostBridgeCapabilityState {
    store.hostBridgeCapabilityState(for: "agent-tui")
  }

  private var agentTuiBridgeCommand: String {
    store.hostBridgeStartCommand(for: "agent-tui")
  }

  private var hostBridge: HostBridgeManifest {
    store.daemonStatus?.manifest?.hostBridge ?? HostBridgeManifest()
  }

  private var agentTuiBridgeCapabilityPresent: Bool {
    hostBridge.capabilities["agent-tui"] != nil
  }

  private var selectedTuiBinding: Binding<String> {
    Binding(
      get: { store.selectedAgentTui?.tuiId ?? "" },
      set: { value in
        store.selectAgentTui(tuiID: value.isEmpty ? nil : value)
        syncTerminalSize()
      }
    )
  }

  private var trimmedInput: String {
    inputText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canStart: Bool {
    !isSubmitting && rows > 0 && cols > 0
  }

  private var canSend: Bool {
    guard let selectedTui else { return false }
    return selectedTui.status.isActive && !trimmedInput.isEmpty && !isSubmitting
  }

  private var canResize: Bool {
    selectedTui != nil && rows > 0 && cols > 0 && !isSubmitting
  }

  private var canStop: Bool {
    selectedTui?.status.isActive == true && !isSubmitting
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
          if store.agentTuiUnavailable {
            agentTuiUnavailableBanner
          }
          tuiSelectionSection
          launchSection
          if let selectedTui {
            terminalSection(selectedTui)
          } else {
            emptyState
          }
        }
        .padding(HarnessMonitorTheme.spacingLG)
      }
      Divider()
      footer
    }
    .frame(minWidth: 640, idealWidth: 760, minHeight: 620)
    .task {
      await store.refreshSelectedAgentTuis()
      syncTerminalSize()
    }
    .onChange(of: store.selectedAgentTui?.tuiId) {
      syncTerminalSize()
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiSheet)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text("Agent TUI")
        .scaledFont(.system(.title3, design: .rounded, weight: .bold))
      Text(store.selectedSession?.session.title ?? "Selected session")
        .scaledFont(.subheadline)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var tuiSelectionSection: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack {
        Text("Sessions")
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Spacer()
        Button("Refresh") {
          refreshSelectedTui()
        }
        .harnessActionButtonStyle(variant: .bordered, tint: nil)
        .disabled(isSubmitting)
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiRefreshButton)
      }
      if store.selectedAgentTuis.isEmpty {
        Text("No agent TUI sessions yet.")
          .scaledFont(.subheadline)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      } else {
        Picker("Agent TUI", selection: selectedTuiBinding) {
          ForEach(store.selectedAgentTuis) { tui in
            Text("\(tui.runtime.capitalized) • \(tui.status.title)").tag(tui.tuiId)
          }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiSelector)
      }
    }
  }

  private var launchSection: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Launch")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Picker("Runtime", selection: $runtime) {
        ForEach(AgentTuiRuntime.allCases) { runtime in
          Text(runtime.title).tag(runtime)
        }
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiRuntimePicker)
      TextField("Optional display name", text: $name)
        .harnessNativeFormControl()
        .focused($focusedField, equals: .prompt)
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiNameField)
      TextField("Optional first prompt to submit inside the TUI", text: $prompt, axis: .vertical)
        .harnessNativeFormControl()
        .lineLimit(4, reservesSpace: true)
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiPromptField)
      HStack(spacing: HarnessMonitorTheme.sectionSpacing) {
        Stepper("Rows \(rows)", value: $rows, in: 16 ... 80)
        Stepper("Cols \(cols)", value: $cols, in: 60 ... 220, step: 10)
        Spacer()
        Button("Start \(runtime.title)") {
          startTui()
        }
        .keyboardShortcut(.defaultAction)
        .harnessActionButtonStyle(variant: .prominent, tint: nil)
        .disabled(!canStart)
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiStartButton)
      }
    }
  }

  private var emptyState: some View {
    Text("Start a terminal-backed agent to inspect the live screen and steer it from Harness Monitor.")
      .scaledFont(.subheadline)
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
  }

  private func terminalSection(_ tui: AgentTuiSnapshot) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      terminalHeader(tui)
      terminalViewport(tui)
      if let error = tui.error, !error.isEmpty {
        terminalError(error)
      }
      terminalInputControls(tui)
      terminalKeyControls(tui)
      terminalResizeControls(tui)
    }
  }

  private func terminalHeader(_ tui: AgentTuiSnapshot) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.sectionSpacing) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Text("\(tui.runtime.capitalized) • \(tui.status.title)")
          .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
        Text("Cursor \(tui.screen.cursorRow):\(tui.screen.cursorCol) • \(tui.size.rows)x\(tui.size.cols)")
          .scaledFont(.caption.monospacedDigit())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      Spacer()
      Button("Transcript") {
        revealTranscript(tui)
      }
      .harnessActionButtonStyle(variant: .bordered, tint: nil)
      .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiRevealTranscriptButton)
      Button("Stop") {
        stopTui(tui)
      }
      .harnessActionButtonStyle(variant: .bordered, tint: nil)
      .disabled(!canStop)
      .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiStopButton)
    }
  }

  private func terminalViewport(_ tui: AgentTuiSnapshot) -> some View {
    ScrollView([.horizontal, .vertical]) {
      Text(tui.screen.text.isEmpty ? "No terminal output yet." : tui.screen.text)
        .scaledFont(.system(.body, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HarnessMonitorTheme.spacingMD)
    }
    .frame(minHeight: 220, maxHeight: 320)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
  }

  private func terminalError(_ error: String) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text("Error")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text(error)
        .scaledFont(.subheadline)
        .foregroundStyle(HarnessMonitorTheme.danger)
        .textSelection(.enabled)
    }
  }

  private func terminalInputControls(_ tui: AgentTuiSnapshot) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Input")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Picker("Input mode", selection: $inputMode) {
        ForEach(AgentTuiInputMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiInputModePicker)
      HStack(alignment: .top, spacing: HarnessMonitorTheme.sectionSpacing) {
        TextField("Text to send to the TUI", text: $inputText, axis: .vertical)
          .harnessNativeFormControl()
          .lineLimit(3, reservesSpace: true)
          .focused($focusedField, equals: .input)
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiInputField)
        Button("Send") {
          sendInput(to: tui)
        }
        .harnessActionButtonStyle(variant: .bordered, tint: nil)
        .disabled(!canSend)
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiSendButton)
      }
    }
  }

  private func terminalKeyControls(_ tui: AgentTuiSnapshot) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Keys")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 90), spacing: HarnessMonitorTheme.itemSpacing)],
        alignment: .leading,
        spacing: HarnessMonitorTheme.itemSpacing
      ) {
        ForEach(commonKeys) { key in
          Button(key.title) {
            sendKey(key, to: tui)
          }
          .harnessActionButtonStyle(variant: .bordered, tint: nil)
          .disabled(!tui.status.isActive || isSubmitting)
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiKeyButton(key.rawValue))
        }
        Button("Ctrl-C") {
          sendControl("c", to: tui)
        }
        .harnessActionButtonStyle(variant: .bordered, tint: nil)
        .disabled(!tui.status.isActive || isSubmitting)
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiKeyButton("ctrl-c"))
      }
    }
  }

  private func terminalResizeControls(_ tui: AgentTuiSnapshot) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Viewport")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      HStack(spacing: HarnessMonitorTheme.sectionSpacing) {
        Stepper("Rows \(rows)", value: $rows, in: 16 ... 80)
        Stepper("Cols \(cols)", value: $cols, in: 60 ... 220, step: 10)
        Spacer()
        Button("Apply Size") {
          resizeTui(tui)
        }
        .harnessActionButtonStyle(variant: .bordered, tint: nil)
        .disabled(!canResize)
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiResizeButton)
      }
    }
  }

  private var footer: some View {
    HStack {
      Button("Close") {
        dismiss()
      }
      .keyboardShortcut(.cancelAction)
      Spacer()
    }
    .padding(HarnessMonitorTheme.spacingLG)
  }

  private var agentTuiUnavailableBanner: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Label(agentTuiBridgeTitle, systemImage: "exclamationmark.triangle")
        .scaledFont(.headline)
        .foregroundStyle(.orange)
      Text(agentTuiBridgeMessage)
        .scaledFont(.subheadline)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      if agentTuiBridgeState == .excluded && hostBridge.running {
        Button("Enable now") {
          Task {
            _ = await store.setHostBridgeCapability("agent-tui", enabled: true)
          }
        }
        .harnessActionButtonStyle(variant: .prominent, tint: nil)
        .disabled(store.isDaemonActionInFlight || isSubmitting)
      }
      CopyableCommandBox(
        command: agentTuiBridgeCommand,
        accessibilityIdentifier: HarnessMonitorAccessibility.agentTuiCopyCommandButton
      )
    }
    .padding(HarnessMonitorTheme.spacingMD)
    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiRecoveryBanner)
  }

  private var agentTuiBridgeTitle: String {
    switch agentTuiBridgeState {
    case .excluded:
      "Agent TUI is excluded from the host bridge"
    case .unavailable:
      "Agent TUI host bridge is not running"
    case .ready:
      "Agent TUI host bridge ready"
    }
  }

  private var agentTuiBridgeMessage: String {
    switch agentTuiBridgeState {
    case .excluded:
      "The shared host bridge is running without terminal control enabled. Enable it now or run this in a terminal:"
    case .unavailable:
      if hostBridge.running && agentTuiBridgeCapabilityPresent {
        "The shared host bridge is running, but terminal control is unavailable. Re-enable it or run this in a terminal:"
      } else {
        "Harness Monitor runs sandboxed and needs the host bridge to start or steer terminal-backed agents. Run this in a terminal:"
      }
    case .ready:
      ""
    }
  }

  private func syncTerminalSize() {
    guard let selectedTui else { return }
    rows = selectedTui.size.rows
    cols = selectedTui.size.cols
  }

  private func startTui() {
    isSubmitting = true
    Task {
      let success = await store.startAgentTui(
        runtime: runtime,
        name: name,
        prompt: prompt,
        rows: rows,
        cols: cols
      )
      if success {
        prompt = ""
        inputText = ""
        focusedField = .input
        syncTerminalSize()
      }
      isSubmitting = false
    }
  }

  private func refreshSelectedTui() {
    isSubmitting = true
    Task {
      if selectedTui != nil {
        _ = await store.refreshSelectedAgentTui()
      } else {
        _ = await store.refreshSelectedAgentTuis()
      }
      syncTerminalSize()
      isSubmitting = false
    }
  }

  private func sendInput(to tui: AgentTuiSnapshot) {
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

  private func sendKey(_ key: AgentTuiKey, to tui: AgentTuiSnapshot) {
    isSubmitting = true
    Task {
      _ = await store.sendAgentTuiInput(tuiID: tui.tuiId, input: .key(key))
      isSubmitting = false
    }
  }

  private func sendControl(_ key: Character, to tui: AgentTuiSnapshot) {
    isSubmitting = true
    Task {
      _ = await store.sendAgentTuiInput(tuiID: tui.tuiId, input: .control(key))
      isSubmitting = false
    }
  }

  private func resizeTui(_ tui: AgentTuiSnapshot) {
    isSubmitting = true
    Task {
      _ = await store.resizeAgentTui(tuiID: tui.tuiId, rows: rows, cols: cols)
      isSubmitting = false
    }
  }

  private func stopTui(_ tui: AgentTuiSnapshot) {
    isSubmitting = true
    Task {
      _ = await store.stopAgentTui(tuiID: tui.tuiId)
      isSubmitting = false
    }
  }

  private func revealTranscript(_ tui: AgentTuiSnapshot) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tui.transcriptPath)])
  }
}
