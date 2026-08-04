import HarnessMonitorKit
import SwiftUI

struct DashboardTerminalAgentDetailView: View {
  let store: HarnessMonitorStore
  let agent: DashboardAgentSummary
  @Bindable var state: DashboardTerminalAgentDetailState
  var teamDecisions: [DashboardDecisionItem] = []
  let loadsAutomatically: Bool
  let onMembershipRemoved: () -> Void
  @State private var isConfirmingRemoval = false
  @State private var signalState = DashboardTerminalSignalState()
  @State private var membershipRefreshID = UUID()

  var body: some View {
    Group {
      if !state.represents(agentID: agent.managedAgentID) {
        loading
      } else if state.isLoading, state.detail == nil {
        loading
      } else if let detail = state.detail {
        detailContent(detail)
      } else {
        unavailable
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardAgentDetail)
    .task(id: membershipLoadIdentity) {
      signalState.prepare(agentID: agent.managedAgentID)
      guard loadsAutomatically else { return }
      await requestMembershipLoad()
    }
    .task(id: agent.identity.id) {
      guard loadsAutomatically else { return }
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(1))
        } catch {
          return
        }
        if state.detail?.snapshot?.status.isActive == false { return }
        _ = requestLoad(checksMembership: false)
      }
    }
    .confirmationDialog(
      "Remove terminal agent from this workspace?",
      isPresented: $isConfirmingRemoval
    ) {
      Button("Remove agent", role: .destructive) { removeMembership() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The retained process outcome and transcript remain available to the daemon")
    }
  }

  private var loading: some View {
    ProgressView("Loading terminal agent")
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func detailContent(_ detail: DashboardTerminalAgentDetail) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        DashboardAgentDetailHeader(agent: agent)
        DashboardAgentDecisionsSection(store: store, items: teamDecisions)
        DashboardTerminalStatusCard(detail: detail)
        DashboardAcpIssues(issues: detail.issues)
        if let snapshot = detail.snapshot {
          DashboardAcpSection(title: "Terminal output") {
            DashboardTerminalViewport(snapshot: snapshot, onResize: resize)
              .id(snapshot.tuiId)
          }
          DashboardTerminalComposer(
            state: state,
            isTerminalActive: snapshot.status.isActive,
            onSend: sendInput,
            onControl: sendControl
          )
          if canSendSignal(detail) {
            DashboardTerminalSignalComposer(
              state: signalState,
              agentID: agent.managedAgentID,
              isEnabled: snapshot.status.isActive && !signalState.isSending,
              onSend: sendSignal
            )
          }
          DashboardTerminalRuntimeFacts(snapshot: snapshot)
        }
        actionRow(detail)
        DashboardAgentIdentityCard(agent: agent)
      }
      .frame(maxWidth: 760, alignment: .leading)
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
  }

  private var automaticLoadIdentity: String {
    "\(agent.identity.id):\(store.connectionState.refreshIdentity)"
  }

  private var membershipLoadIdentity: String {
    "\(automaticLoadIdentity):\(membershipRefreshID)"
  }

  private func requestMembershipRefresh() {
    membershipRefreshID = UUID()
  }

  private var unavailable: some View {
    ContentUnavailableView {
      Label("Terminal details unavailable", systemImage: "network.slash")
    } description: {
      Text("Ask the daemon to reconcile this managed terminal identity")
    } actions: {
      Button("Refresh details") { requestMembershipRefresh() }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func actionRow(_ detail: DashboardTerminalAgentDetail) -> some View {
    HStack {
      Button {
        requestMembershipRefresh()
      } label: {
        Label("Refresh details", systemImage: "arrow.clockwise")
      }
      .disabled(state.isLoading || state.activeAction != nil)
      Spacer()
      if detail.snapshot?.status.isActive == true {
        Button("Stop agent", role: .destructive) { stop() }
          .disabled(state.activeAction != nil)
          .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardTerminalStopButton)
      } else if detail.isMember == false || state.membershipRemoved {
        Text("Removed from workspace")
          .scaledFont(.caption.weight(.medium))
          .foregroundStyle(.secondary)
      } else if canRemoveMembership {
        Button("Remove agent", role: .destructive) { isConfirmingRemoval = true }
          .disabled(state.activeAction != nil || state.membershipRemoved)
          .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardTerminalRemoveButton)
      } else {
        Text(detail.continuity.title)
          .scaledFont(.caption.weight(.medium))
          .foregroundStyle(.secondary)
      }
    }
  }

  private var canRemoveMembership: Bool {
    guard let sessionAgentID = agent.sessionAgentID else { return false }
    return !sessionAgentID.isEmpty
  }

  private func canSendSignal(_ detail: DashboardTerminalAgentDetail) -> Bool {
    guard detail.isMember == true else { return false }
    guard let sessionAgentID = agent.sessionAgentID else { return false }
    return !sessionAgentID.isEmpty
  }

  private func requestMembershipLoad() async {
    while !Task.isCancelled {
      if requestLoad(checksMembership: true) { return }
      do {
        try await Task.sleep(for: .milliseconds(100))
      } catch {
        return
      }
    }
  }

  @discardableResult
  private func requestLoad(checksMembership: Bool = true) -> Bool {
    guard let generation = state.beginLoad(agentID: agent.managedAgentID) else { return false }
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Loading Dashboard terminal agent") {
        let detail = await store.dashboardTerminalAgentDetail(
          managedAgentID: agent.managedAgentID,
          sessionID: agent.sessionID,
          sessionAgentID: agent.sessionAgentID,
          checksMembership: checksMembership
        )
        await state.finishLoad(detail, generation: generation)
      }
    )
    return true
  }

  private func sendInput() {
    let text = state.input
    guard !text.isEmpty else { return }
    submitAction("Sending terminal input", clearsInput: true) {
      await store.sendDashboardTerminalInputSequence(
        agentID: agent.managedAgentID,
        inputs: [.text(text), .key(.enter)]
      )
    }
  }

  private func sendControl(_ input: AgentTuiInput) {
    submitAction("Sending terminal control") {
      await store.sendDashboardTerminalInput(
        agentID: agent.managedAgentID,
        input: input
      )
    }
  }

  private func resize(_ size: AgentTuiSize) async -> Bool {
    await withCheckedContinuation { continuation in
      HarnessMonitorAsyncWorkQueue.shared.submit(
        .init(title: "Resizing Dashboard terminal") {
          let snapshot = await store.resizeDashboardTerminalAgent(
            agentID: agent.managedAgentID,
            rows: size.rows,
            cols: size.cols,
            feedback: .silent
          )
          continuation.resume(returning: snapshot != nil)
        }
      )
    }
  }

  private func stop() {
    submitAction("Stopping terminal agent") {
      await store.stopDashboardTerminalAgent(agentID: agent.managedAgentID)
    }
  }

  private func sendSignal() {
    guard
      let sessionAgentID = agent.sessionAgentID,
      let token = signalState.beginSend(agentID: agent.managedAgentID)
    else { return }
    let command = signalState.trimmedCommand
    let message = signalState.trimmedMessage
    let actionHint = signalState.trimmedActionHint
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Sending Dashboard terminal signal") {
        let succeeded = await store.sendDashboardTerminalSignal(
          sessionID: agent.sessionID,
          sessionAgentID: sessionAgentID,
          command: command,
          message: message,
          actionHint: actionHint
        )
        await signalState.finishSend(token, succeeded: succeeded)
      }
    )
  }

  private func removeMembership() {
    guard let sessionAgentID = agent.sessionAgentID else { return }
    let title = "Removing terminal agent"
    guard let token = state.beginAction(title) else { return }
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: title) {
        let succeeded = await store.removeDashboardTerminalMembership(
          sessionID: agent.sessionID,
          sessionAgentID: sessionAgentID
        )
        await state.finishRemoval(token, succeeded: succeeded)
        if succeeded { await MainActor.run { onMembershipRemoved() } }
      }
    )
  }

  private func submitAction(
    _ title: String,
    clearsInput: Bool = false,
    operation: @escaping @Sendable () async -> AgentTuiSnapshot?
  ) {
    guard let token = state.beginAction(title) else { return }
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: title) {
        let snapshot = await operation()
        if clearsInput {
          await state.finishInput(token, snapshot: snapshot)
        } else {
          await state.finishAction(token, snapshot: snapshot)
        }
      }
    )
  }
}
