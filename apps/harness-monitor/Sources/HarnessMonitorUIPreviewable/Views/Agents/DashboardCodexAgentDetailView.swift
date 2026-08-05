import HarnessMonitorKit
import SwiftUI

struct DashboardCodexAgentDetailView: View {
  let store: HarnessMonitorStore
  let agent: DashboardAgentSummary
  @Bindable var state: DashboardCodexAgentDetailState
  var teamDecisions: [DashboardDecisionItem] = []
  let loadsAutomatically: Bool

  var body: some View {
    DashboardDecisionScrollView(store: store, decisionIDs: navigationDecisionIDs) {
      VStack(alignment: .leading, spacing: 20) {
        DashboardAgentDetailHeader(agent: agent)
        DashboardAgentDecisionsSection(store: store, items: teamDecisions)
        if state.isLoading, state.detail == nil {
          ProgressView("Loading Codex agent")
            .frame(maxWidth: .infinity, minHeight: 180)
        } else if let detail = state.detail {
          DashboardCodexStatusCard(detail: detail)
          DashboardAcpIssues(issues: detail.issues)
          summary(detail)
          DashboardCodexApprovals(
            store: store,
            sessionID: agent.sessionID,
            approvals: detail.pendingApprovals,
            isBusy: state.activeAction != nil,
            onResolve: resolveApproval
          )
          DashboardAcpTranscript(entries: detail.transcript)
          DashboardCodexActivity(events: detail.run?.events ?? [])
          promptComposer(detail)
          actionRow(detail)
          DashboardAgentIdentityCard(agent: agent)
        } else {
          ContentUnavailableView {
            Label("Codex details unavailable", systemImage: "network.slash")
          } description: {
            Text("Ask the daemon for the current managed run and transcript")
          } actions: {
            Button("Refresh details") { requestLoad() }
          }
        }
      }
      .frame(maxWidth: 760, alignment: .leading)
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardAgentDetail)
    .task(id: "\(agent.identity.id):\(agent.updatedAt)") {
      guard loadsAutomatically else { return }
      requestLoad()
    }
  }

  private var navigationDecisionIDs: Set<String> {
    let approvalIDs =
      state.detail?.pendingApprovals.map {
        CodexApprovalRule.decisionID(sessionID: agent.sessionID, approvalID: $0.id)
      } ?? []
    return Set(teamDecisions.map(\.id) + approvalIDs)
  }

  private func summary(_ detail: DashboardCodexAgentDetail) -> some View {
    DashboardAcpSection(title: "Run summary") {
      if let run = detail.run {
        detailRow("Prompt", run.prompt)
        if let latest = run.latestSummary { detailRow("Latest", latest) }
        if let final = run.finalMessage { detailRow("Final", final) }
        if let error = run.error { detailRow("Failure", error) }
      } else {
        Text("The managed run snapshot is unavailable")
          .foregroundStyle(.secondary)
      }
    }
  }

  private func detailRow(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).scaledFont(.caption.weight(.medium)).foregroundStyle(.secondary)
      Text(value.withoutTrailingPeriod).textSelection(.enabled)
    }
  }

  private func promptComposer(_ detail: DashboardCodexAgentDetail) -> some View {
    DashboardAcpSection(title: "Steer") {
      TextEditor(text: $state.prompt)
        .font(.body)
        .frame(minHeight: 84, maxHeight: 150)
        .padding(6)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary) }
        .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardCodexSteerField)
      HStack {
        Text(steerAvailability(detail))
          .scaledFont(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Send context") { sendContext() }
          .buttonStyle(.borderedProminent)
          .disabled(!canSteer(detail))
          .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardCodexSteerButton)
      }
    }
  }

  private func actionRow(_ detail: DashboardCodexAgentDetail) -> some View {
    HStack {
      Button {
        requestLoad()
      } label: {
        Label("Refresh details", systemImage: "arrow.clockwise")
      }
      .disabled(state.isLoading || state.activeAction != nil)
      Spacer()
      if detail.run?.status.isActive == true {
        Button("Interrupt") { interrupt() }
          .disabled(state.activeAction != nil)
          .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardCodexInterruptButton)
        Button("Stop agent", role: .destructive) { stop() }
          .disabled(state.activeAction != nil)
          .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardCodexStopButton)
      } else {
        Text(detail.continuity.title)
          .scaledFont(.caption.weight(.medium))
          .foregroundStyle(.secondary)
      }
    }
  }

  private func steerAvailability(_ detail: DashboardCodexAgentDetail) -> String {
    detail.run?.status.isActive == true
      ? "Context is sent to managed identity \(agent.managedAgentID)"
      : "Terminal runs cannot receive more context"
  }

  private func canSteer(_ detail: DashboardCodexAgentDetail) -> Bool {
    detail.run?.status.isActive == true && state.activeAction == nil
      && !state.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func requestLoad() {
    let generation = state.beginLoad()
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Loading Dashboard Codex agent") {
        let detail = await store.dashboardCodexAgentDetail(
          managedAgentID: agent.managedAgentID,
          sessionID: agent.sessionID,
          sessionAgentID: agent.sessionAgentID
        )
        await state.finishLoad(detail, generation: generation)
      }
    )
  }

  private func sendContext() {
    let prompt = state.prompt
    submitAction("Sending Codex context") {
      let snapshot = await store.steerDashboardCodexAgent(
        agentID: agent.managedAgentID,
        prompt: prompt
      )
      if snapshot != nil { await MainActor.run { state.prompt = "" } }
      return snapshot != nil
    }
  }

  private func interrupt() {
    submitAction("Interrupting Codex agent") {
      await store.interruptDashboardCodexAgent(agentID: agent.managedAgentID) != nil
    }
  }

  private func stop() {
    submitAction("Stopping Codex agent") {
      await store.stopDashboardCodexAgent(agentID: agent.managedAgentID) != nil
    }
  }

  private func resolveApproval(
    _ approval: CodexApprovalRequest,
    _ decision: CodexApprovalDecision
  ) {
    submitAction("Resolving Codex approval") {
      await store.resolveDashboardCodexApproval(
        agentID: agent.managedAgentID,
        approvalID: approval.approvalId,
        decision: decision
      ) != nil
    }
  }

  private func submitAction(
    _ title: String,
    operation: @escaping @Sendable () async -> Bool
  ) {
    guard state.beginAction(title) else { return }
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: title) {
        let succeeded = await operation()
        await state.finishAction(title)
        if succeeded { await MainActor.run { requestLoad() } }
      }
    )
  }
}
