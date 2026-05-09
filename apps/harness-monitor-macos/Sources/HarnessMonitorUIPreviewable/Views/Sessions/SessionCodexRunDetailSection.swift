import HarnessMonitorKit
import SwiftUI

struct SessionCodexRunDetailSection: View {
  let store: HarnessMonitorStore
  let run: CodexRunSnapshot
  @Environment(\.fontScale)
  private var fontScale
  @State private var contextDraft: String = ""

  private var metrics: SessionAgentDetailSectionMetrics {
    SessionAgentDetailSectionMetrics(fontScale: fontScale)
  }

  private var isActive: Bool { run.status.isActive }
  private var isInterrupting: Bool { store.isInterruptCodexRunInFlight(run.runId) }
  private var canSteer: Bool {
    isActive
      && !contextDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !store.isSessionActionInFlight
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
        header
        if let error = run.error, !error.isEmpty {
          SessionAgentTuiErrorBanner(message: error)
        }
        block(
          label: "Prompt",
          body: run.prompt.isEmpty ? "(empty prompt)" : run.prompt,
          tint: 0.4
        )
        if let summary = run.latestSummary, !summary.isEmpty {
          block(label: "Latest update", body: summary, tint: 0.25)
        }
        if let final = run.finalMessage, !final.isEmpty {
          block(label: "Final message", body: final, tint: 0.25)
        }
        if !run.pendingApprovals.isEmpty {
          approvalsSection
        }
        if isActive {
          steerComposer
        }
      }
      .padding(metrics.sectionPadding)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .dynamicTypeSize(.xSmall ... .accessibility5)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingMD) {
      VStack(alignment: .leading, spacing: metrics.headerSpacing) {
        Text(SessionCodexRunRowFormatter.title(for: run))
          .scaledFont(.title3.weight(.semibold))
          .lineLimit(2)
        Text("Codex • \(run.mode.title) • \(run.status.title)")
          .scaledFont(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .accessibilityElement(children: .combine)
      Spacer(minLength: 0)
      if isActive {
        Button(isInterrupting ? "Interrupting…" : "Interrupt") {
          store.requestInterruptCodexRunConfirmation(run)
        }
        .disabled(isInterrupting)
        .help("Interrupt this Codex run")
        .accessibilityLabel("Interrupt Codex run")
      }
    }
  }

  @ViewBuilder
  private func block(label: String, body: String, tint: Double) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label)
        .scaledFont(.caption.bold())
        .foregroundStyle(.secondary)
      Text(body)
        .scaledFont(.body)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(metrics.terminalPadding)
    .background(
      .quaternary.opacity(tint),
      in: RoundedRectangle(cornerRadius: metrics.terminalCornerRadius)
    )
  }

  private var approvalsSection: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      HStack(spacing: 6) {
        Image(systemName: "exclamationmark.shield.fill")
          .foregroundStyle(.orange)
        Text("Approvals")
          .scaledFont(.caption.bold())
          .foregroundStyle(.secondary)
      }
      ForEach(run.pendingApprovals) { approval in
        approvalCard(approval)
      }
    }
  }

  private func approvalCard(_ approval: CodexApprovalRequest) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(approval.title)
        .scaledFont(.headline)
      if !approval.detail.isEmpty {
        Text(approval.detail)
          .scaledFont(.subheadline)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        ForEach(CodexApprovalDecision.allCases, id: \.self) { decision in
          Button(decisionLabel(decision)) {
            resolve(approval: approval, decision: decision)
          }
          .disabled(store.isSessionActionInFlight)
        }
        Spacer(minLength: 0)
      }
    }
    .padding(metrics.terminalPadding)
    .background(
      .regularMaterial,
      in: RoundedRectangle(cornerRadius: metrics.terminalCornerRadius, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: metrics.terminalCornerRadius, style: .continuous)
        .stroke(.quaternary, lineWidth: 1)
    )
  }

  private func decisionLabel(_ decision: CodexApprovalDecision) -> String {
    switch decision {
    case .accept: "Accept"
    case .acceptForSession: "Accept for session"
    case .decline: "Decline"
    case .cancel: "Cancel"
    }
  }

  private func resolve(approval: CodexApprovalRequest, decision: CodexApprovalDecision) {
    Task {
      _ = await store.resolveCodexApproval(
        runID: run.runId,
        approvalID: approval.approvalId,
        decision: decision
      )
    }
  }

  private var steerComposer: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Send context")
        .scaledFont(.caption.bold())
        .foregroundStyle(.secondary)
      TextEditor(text: $contextDraft)
        .scaledFont(.body)
        .frame(minHeight: 88, maxHeight: 220)
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(
          .quaternary.opacity(0.2),
          in: RoundedRectangle(cornerRadius: metrics.terminalCornerRadius)
        )
        .overlay(
          RoundedRectangle(cornerRadius: metrics.terminalCornerRadius)
            .stroke(.quaternary, lineWidth: 1)
        )
        .accessibilityLabel("Codex context")
      HStack {
        Spacer(minLength: 0)
        Button("Send context") {
          steerWithDraft()
        }
        .keyboardShortcut(.return, modifiers: [.command])
        .disabled(!canSteer)
      }
    }
  }

  private func steerWithDraft() {
    let prompt = contextDraft
    Task {
      let success = await store.steerCodexRun(runID: run.runId, prompt: prompt)
      if success {
        contextDraft = ""
      }
    }
  }
}
