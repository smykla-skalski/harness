import HarnessMonitorKit
import SwiftUI

@MainActor
public struct SessionOpenRouterRunDetailSection: View {
  public let store: HarnessMonitorStore
  public let run: OpenRouterRunSnapshot
  @State private var followUpPrompt = ""
  @FocusState private var promptFocused: Bool

  public init(store: HarnessMonitorStore, run: OpenRouterRunSnapshot) {
    self.store = store
    self.run = run
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      header
      transcriptCard
      reasoningCard
      pendingPermissionsCard
      followUpCard
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionOpenRouterRunDetail)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        Text(run.displayName)
          .scaledFont(.headline)
        Spacer()
        statusBadge
      }
      Text(run.model)
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text("Turns: \(run.turnCount)")
        .scaledFont(.caption2)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
  }

  private var statusBadge: some View {
    Text(run.status.title)
      .scaledFont(.caption.bold())
      .padding(.horizontal, HarnessMonitorTheme.spacingSM)
      .padding(.vertical, 2)
      .background(statusTint.opacity(0.18), in: Capsule())
      .foregroundStyle(statusTint)
  }

  private var statusTint: Color {
    switch run.status {
    case .pending:
      HarnessMonitorTheme.secondaryInk
    case .streaming:
      HarnessMonitorTheme.accent
    case .idle:
      HarnessMonitorTheme.success
    case .cancelled:
      HarnessMonitorTheme.caution
    case .failed:
      HarnessMonitorTheme.danger
    }
  }

  @ViewBuilder private var transcriptCard: some View {
    if let text = run.latestMessage ?? run.finalMessage, !text.isEmpty {
      cardSection(title: "Latest message") {
        Text(text)
          .scaledFont(.body)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    } else if let err = run.error {
      cardSection(title: "Error") {
        Text(err)
          .scaledFont(.body)
          .foregroundStyle(HarnessMonitorTheme.danger)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  @ViewBuilder private var reasoningCard: some View {
    if let reasoning = run.latestReasoning, !reasoning.isEmpty {
      cardSection(title: "Reasoning") {
        Text(reasoning)
          .scaledFont(.body.monospaced())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  @ViewBuilder private var pendingPermissionsCard: some View {
    if !run.pendingPermissionBatches.isEmpty {
      cardSection(title: "Pending tool permissions") {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          ForEach(run.pendingPermissionBatches) { batch in
            HStack {
              Text("Batch \(batch.batchId.prefix(8)) — \(batch.requests.count) request(s)")
                .scaledFont(.caption)
              Spacer()
              Button("Approve") {
                Task { await resolve(batch.batchId, decision: .approveAll) }
              }
              .buttonStyle(.borderless)
              Button(role: .destructive) {
                Task { await resolve(batch.batchId, decision: .denyAll) }
              } label: {
                Text("Deny")
              }
              .buttonStyle(.borderless)
            }
          }
        }
      }
    }
  }

  private var followUpCard: some View {
    cardSection(title: "Send follow-up") {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        HarnessMonitorMultilineTextField<Never>(
          placeholder: "Reply or ask a follow-up...",
          text: $followUpPrompt,
          minHeight: 80,
          accessibilityLabel: "Follow-up prompt"
        )
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.sessionOpenRouterRunPromptField
        )
        HStack {
          Button(role: .destructive) {
            Task { await cancelRun() }
          } label: {
            Label("Cancel turn", systemImage: "stop.circle")
          }
          .buttonStyle(.borderless)
          .disabled(!run.status.isActive)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.sessionOpenRouterRunCancelButton
          )
          Spacer()
          Button {
            Task { await sendPrompt() }
          } label: {
            Label("Send", systemImage: "paperplane.fill")
              .scaledFont(.body.weight(.semibold))
          }
          .buttonStyle(.borderedProminent)
          .disabled(
            followUpPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || run.status.isActive
          )
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.sessionOpenRouterRunSendButton
          )
        }
      }
    }
  }

  private func cardSection<Content: View>(
    title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(title)
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      content()
    }
    .padding(HarnessMonitorTheme.spacingMD)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      HarnessMonitorTheme.ink.opacity(0.04),
      in: RoundedRectangle(cornerRadius: 10)
    )
  }

  private func sendPrompt() async {
    let pending = followUpPrompt
    followUpPrompt = ""
    _ = await store.promptOpenRouterRun(runID: run.runId, prompt: pending)
  }

  private func cancelRun() async {
    _ = await store.cancelOpenRouterRun(runID: run.runId)
  }

  private func resolve(_ batchID: String, decision: AcpPermissionDecision) async {
    _ = await store.resolveOpenRouterPermissionBatch(
      runID: run.runId,
      batchID: batchID,
      decision: decision
    )
  }
}
