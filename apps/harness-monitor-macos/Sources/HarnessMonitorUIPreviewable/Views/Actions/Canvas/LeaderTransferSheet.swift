import HarnessMonitorKit
import SwiftUI

struct LeaderTransferSheet: View {
  let store: HarnessMonitorStore
  let sessionID: String
  @Environment(\.dismiss)
  private var dismiss
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration

  @State private var transferLeaderID = ""
  @State private var transferReason = ""

  private var detail: SessionDetail? {
    guard let selected = store.selectedSession,
      selected.session.sessionId == sessionID
    else {
      return nil
    }
    return selected
  }

  private var actionActorID: String { store.selectedActionActorID }

  private var areLeaderActionsAvailable: Bool {
    store.areSelectedLeaderActionsAvailable
  }
  private var effectiveTransferLeaderID: String {
    Self.normalizedTransferLeaderID(
      draftID: transferLeaderID,
      leaderID: detail?.session.leaderId,
      pendingLeaderID: detail?.session.pendingLeaderTransfer?.newLeaderId,
      availableAgentIDs: detail?.agents.map(\.agentId) ?? []
    )
  }
  private var transferLeaderSelection: Binding<String> {
    Binding(
      get: { effectiveTransferLeaderID },
      set: { transferLeaderID = $0 }
    )
  }

  private var transferButtonTitle: String {
    if let detail,
      detail.session.pendingLeaderTransfer != nil,
      actionActorID == detail.session.leaderId
    {
      return "Confirm Leadership Transfer"
    }
    return "Transfer Leadership"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let detail {
        header(for: detail)
        Divider()
        ScrollView {
          form(for: detail)
            .padding(HarnessMonitorTheme.spacingLG)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(detail.agents.count <= 1 || !areLeaderActionsAvailable)
            .opacity(detail.agents.count <= 1 ? 0.4 : 1)
        }
      } else {
        unavailableState
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.leaderTransferSheet)
    .onAppear { syncDefaults() }
    .onChange(of: detail == nil) { _, missing in
      if missing { dismiss() }
    }
  }

  private func header(for detail: SessionDetail) -> some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Text("Leadership")
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Text("Transfer Leadership")
          .scaledFont(.system(.title3, design: .rounded, weight: .bold))
      }
      Spacer()
      Button("Done") { dismiss() }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier(HarnessMonitorAccessibility.leaderTransferSheetDismiss)
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func form(for detail: SessionDetail) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      Text("Promote a live agent to leader when the current leader needs to step away.")
        .scaledFont(.system(.footnote, design: .rounded, weight: .medium))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      if let pendingTransfer = detail.session.pendingLeaderTransfer {
        let timestamp = formatTimestamp(pendingTransfer.requestedAt)
        Text(
          "\(pendingTransfer.requestedBy) requested \(pendingTransfer.newLeaderId) at \(timestamp)."
        )
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      if detail.agents.isEmpty {
        Text("Agent availability is still loading for this session.")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      } else {
        Picker("New Leader", selection: transferLeaderSelection) {
          if let leader = detail.agents.first(where: { $0.agentId == detail.session.leaderId }) {
            Text("\(leader.name) (current leader)")
              .foregroundStyle(.tertiary)
              .tag(leader.agentId)
          }
          ForEach(detail.agents.filter { $0.agentId != detail.session.leaderId }) { agent in
            Text(agent.name).tag(agent.agentId)
          }
        }
        .onChange(of: transferLeaderID) { previous, current in
          if current == detail.session.leaderId, previous != detail.session.leaderId {
            transferLeaderID = previous
          }
        }
        .accessibilityIdentifier(HarnessMonitorAccessibility.leaderTransferPicker)
        .harnessNativeFormControl()
      }
      TextField("Reason", text: $transferReason, axis: .vertical)
        .harnessNativeFormControl()
        .lineLimit(3, reservesSpace: true)
        .submitLabel(.done)
      HarnessInlineActionButton(
        title: transferButtonTitle,
        actionID: .transferLeader(
          sessionID: detail.session.sessionId,
          newLeaderID: effectiveTransferLeaderID
        ),
        store: store,
        variant: .prominent,
        tint: HarnessMonitorTheme.caution,
        isExternallyDisabled:
          effectiveTransferLeaderID.isEmpty
          || effectiveTransferLeaderID == detail.session.leaderId
          || !areLeaderActionsAvailable,
        help:
          effectiveTransferLeaderID == detail.session.leaderId
          ? "Select a different agent to transfer leadership to" : "",
        action: submitTransfer
      )
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.leaderTransferSection)
  }

  private var unavailableState: some View {
    VStack(spacing: HarnessMonitorTheme.spacingMD) {
      Image(systemName: "questionmark.circle")
        .font(.system(size: 36))
        .foregroundStyle(.secondary)
      Text("Session unavailable.")
        .scaledFont(.headline)
      Button("Dismiss") { dismiss() }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier(HarnessMonitorAccessibility.leaderTransferSheetDismiss)
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func syncDefaults() {
    guard let detail else { return }
    if let pendingLeaderID = detail.session.pendingLeaderTransfer?.newLeaderId,
      detail.agents.contains(where: { $0.agentId == pendingLeaderID })
    {
      transferLeaderID = pendingLeaderID
      return
    }
    if transferLeaderID.isEmpty
      || !detail.agents.contains(where: { $0.agentId == transferLeaderID })
    {
      transferLeaderID =
        detail.agents.first(where: { $0.agentId != detail.session.leaderId })?.agentId
        ?? detail.agents.first?.agentId ?? ""
    }
  }

  private func submitTransfer() {
    Task { await transfer() }
  }

  private func transfer() async {
    let reason = transferReason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !effectiveTransferLeaderID.isEmpty else { return }
    let success = await store.transferLeader(
      newLeaderID: effectiveTransferLeaderID,
      reason: reason.isEmpty ? nil : reason
    )
    if success { transferReason = "" }
  }

  static func normalizedTransferLeaderID(
    draftID: String,
    leaderID: String?,
    pendingLeaderID: String?,
    availableAgentIDs: [String]
  ) -> String {
    let eligibleAgentIDs = availableAgentIDs.filter { $0 != leaderID }
    if let pendingLeaderID, eligibleAgentIDs.contains(pendingLeaderID) {
      return pendingLeaderID
    }
    if eligibleAgentIDs.contains(draftID) {
      return draftID
    }
    return eligibleAgentIDs.first ?? availableAgentIDs.first ?? ""
  }
}

#Preview("Leader transfer sheet") {
  LeaderTransferSheet(
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded),
    sessionID: PreviewFixtures.summary.sessionId
  )
  .frame(width: 460, height: 540)
}
