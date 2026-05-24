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
  private var canSendPrompt: Bool {
    run.threadId != nil
      && !contextDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !store.isSessionActionInFlight
  }
  private var canSteer: Bool {
    isActive
      && canSendPrompt
  }
  private var canFollowUp: Bool {
    !isActive
      && canSendPrompt
  }

  var body: some View {
    Group {
      if isActive || run.threadId != nil {
        SessionDetailScrollSurface(
          contentPadding: metrics.sectionPadding,
          bottomInsetSpacing: metrics.sectionSpacing,
          bottomInset: {
            steerComposer
          },
          content: {
            contentColumn
          }
        )
      } else {
        SessionDetailScrollSurface(contentPadding: metrics.sectionPadding) {
          contentColumn
        }
      }
    }
    .dynamicTypeSize(.xSmall ... .accessibility5)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder private var contentColumn: some View {
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
      if !run.events.isEmpty {
        eventsSection
      }
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingMD) {
      VStack(alignment: .leading, spacing: metrics.headerSpacing) {
        Text(SessionCodexRunRowFormatter.title(for: run))
          .scaledFont(.title3.weight(.semibold))
          .lineLimit(2)
        Text(headerSubtitle)
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

  private var headerSubtitle: String {
    let name = run.displayName ?? "Codex"
    if let sessionAgentID = run.sessionAgentID {
      return "\(name) • \(sessionAgentID) • \(run.mode.title) • \(run.status.title)"
    }
    return "\(name) • \(run.mode.title) • \(run.status.title)"
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

  private var eventsSection: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      HStack(spacing: 6) {
        Image(systemName: "list.bullet.rectangle")
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Text("Activity")
          .scaledFont(.caption.bold())
          .foregroundStyle(.secondary)
      }
      ForEach(run.events.suffix(30)) { event in
        eventRow(event)
      }
    }
  }

  private func eventRow(_ event: CodexRunEvent) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
        Text(event.kind)
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.ink)
          .lineLimit(1)
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        Text("#\(event.sequence)")
          .scaledFont(.caption2)
          .foregroundStyle(.secondary)
      }
      Text(event.summary)
        .scaledFont(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, metrics.terminalPadding)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .background(
      .quaternary.opacity(0.18),
      in: RoundedRectangle(cornerRadius: metrics.terminalCornerRadius)
    )
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
    .harnessFloatingControlGlass(
      cornerRadius: metrics.terminalCornerRadius,
      tint: nil,
      prominence: .subdued
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
      Text(isActive ? "Send context" : "Send follow-up")
        .scaledFont(.caption.bold())
        .foregroundStyle(.secondary)
      HarnessMonitorMultilineTextField<Never>(
        placeholder: "",
        text: $contextDraft,
        minHeight: 88,
        maxHeight: 220,
        accessibilityLabel: "Codex context"
      )
      HStack {
        Spacer(minLength: 0)
        Button(isActive ? "Send context" : "Send follow-up") {
          steerWithDraft()
        }
        .keyboardShortcut(.return, modifiers: [.command])
        .disabled(!(canSteer || canFollowUp))
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
