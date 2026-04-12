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
    .task {
      await store.refreshDaemonStatus()
      await store.refreshSelectedCodexRuns()
    }
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
        .accessibilityIdentifier(HarnessMonitorAccessibility.codexFlowEnableBridgeButton)
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
