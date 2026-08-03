import HarnessMonitorKit
import SwiftUI

struct DashboardAcpAgentDetailView: View {
  let store: HarnessMonitorStore
  let agent: DashboardAgentSummary
  @Bindable var state: DashboardAcpAgentDetailState
  var teamDecisions: [DashboardDecisionItem] = []
  let loadsAutomatically: Bool

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        DashboardAgentDetailHeader(agent: agent)
        DashboardAgentDecisionsSection(store: store, items: teamDecisions)
        if state.isLoading, state.detail == nil {
          ProgressView("Loading ACP agent")
            .frame(maxWidth: .infinity, minHeight: 180)
        } else if let detail = state.detail {
          DashboardAcpStatusCard(detail: detail)
          DashboardAcpIssues(issues: detail.issues)
          permissions(detail)
          DashboardAcpTranscript(entries: detail.transcript)
          promptComposer(detail)
          DashboardAcpProviderSessions(
            agentID: agent.managedAgentID,
            detail: detail,
            activeAction: state.activeAction,
            onClose: closeProviderSession,
            onDelete: deleteProviderSession
          )
          actionRow(detail)
          DashboardAgentIdentityCard(agent: agent)
        } else {
          ContentUnavailableView(
            "ACP details unavailable",
            systemImage: "network.slash",
            description: Text("Refresh to ask the daemon for current managed-agent evidence")
          )
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

  @ViewBuilder
  private func permissions(_ detail: DashboardAcpAgentDetail) -> some View {
    if detail.pendingPermissions.isEmpty {
      DashboardAcpSection(title: "Permissions") {
        Label("No permission requests are pending", systemImage: "checkmark.shield")
          .foregroundStyle(.secondary)
      }
    } else {
      ForEach(detail.pendingPermissions) { batch in
        DashboardAcpPermissionCard(
          store: store,
          batch: batch,
          isBusy: state.activeAction != nil,
          onResolve: resolvePermission
        )
      }
    }
  }

  private func promptComposer(_ detail: DashboardAcpAgentDetail) -> some View {
    DashboardAcpSection(title: "Prompt") {
      VStack(alignment: .leading, spacing: 10) {
        TextEditor(text: $state.prompt)
          .font(.body)
          .frame(minHeight: 84, maxHeight: 150)
          .padding(6)
          .background(.background, in: RoundedRectangle(cornerRadius: 8))
          .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary) }
        HStack {
          Text(promptAvailability(detail))
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Button("Send prompt") { sendPrompt() }
            .buttonStyle(.borderedProminent)
            .disabled(
              state.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || state.activeAction != nil || detail.agent?.status == .removed
            )
        }
      }
    }
  }

  private func actionRow(_ detail: DashboardAcpAgentDetail) -> some View {
    HStack {
      Button {
        requestLoad()
      } label: {
        Label("Refresh details", systemImage: "arrow.clockwise")
      }
      .disabled(state.isLoading || state.activeAction != nil)
      Spacer()
      if detail.handshake?.supportsLogout == true {
        Button("Log out provider", role: .destructive) { logout() }
          .disabled(state.activeAction != nil)
      } else {
        Text("Provider logout unsupported")
          .scaledFont(.caption)
          .foregroundStyle(.secondary)
      }
      Button("Stop agent", role: .destructive) { stop() }
        .disabled(state.activeAction != nil || detail.agent?.status == .removed)
    }
  }

  private func promptAvailability(_ detail: DashboardAcpAgentDetail) -> String {
    if detail.agent?.status == .removed { return "Stopped agents cannot receive prompts" }
    if let failure = detail.sessionState?.lastTurnFailure {
      let category = failure.category.rawValue.replacingOccurrences(of: "_", with: " ")
      return "Last prompt failed: \(category)"
    }
    return "Prompts are sent to managed identity \(agent.managedAgentID)"
  }

  private func requestLoad() {
    let generation = state.beginLoad()
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Loading Dashboard ACP agent") {
        let detail = await store.dashboardAcpAgentDetail(
          managedAgentID: agent.managedAgentID,
          sessionID: agent.sessionID,
          sessionAgentID: agent.sessionAgentID,
          projectDirectory: agent.projectDirectory
        )
        await state.finishLoad(detail, generation: generation)
      }
    )
  }

  private func sendPrompt() {
    let prompt = state.prompt
    submitAction("Sending prompt") {
      let snapshot = await store.promptDashboardAcpAgent(
        agentID: agent.managedAgentID,
        prompt: prompt
      )
      if snapshot != nil { await MainActor.run { state.prompt = "" } }
      return snapshot != nil
    }
  }

  private func stop() {
    submitAction("Stopping agent") {
      await store.stopDashboardAcpAgent(agentID: agent.managedAgentID) != nil
    }
  }

  private func logout() {
    submitAction("Logging out provider") {
      await store.logoutDashboardAcpAgent(agentID: agent.managedAgentID)
    }
  }

  private func closeProviderSession(_ sessionID: String) {
    submitAction("Closing provider session") {
      await store.closeDashboardAcpSession(
        agentID: agent.managedAgentID,
        sessionID: sessionID
      )
    }
  }

  private func deleteProviderSession(_ sessionID: String) {
    submitAction("Deleting provider session") {
      await store.deleteDashboardAcpSession(
        agentID: agent.managedAgentID,
        sessionID: sessionID
      )
    }
  }

  private func resolvePermission(
    _ batch: AcpPermissionBatch,
    _ decision: AcpPermissionDecision
  ) {
    submitAction("Resolving permission") {
      await store.resolveAcpPermission(batch: batch, decision: decision)
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

struct DashboardAcpSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  init(title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).scaledFont(.headline)
      content
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
  }
}
