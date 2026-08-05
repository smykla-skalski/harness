import HarnessMonitorKit
import SwiftUI

struct DashboardAcpStatusCard: View {
  let detail: DashboardAcpAgentDetail

  var body: some View {
    DashboardAcpSection(title: "Runtime and continuity") {
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
        fact("Restart", detail.continuity.title)
        fact("Evidence", detail.continuity.detail)
        fact("Transport", detail.inspect == nil ? "Unavailable" : "Connected")
        fact("Authentication", authenticationText)
        if let failure = detail.sessionState?.lastTurnFailure {
          fact("Last failure", failureText(failure))
        }
      }
      if let handshake = detail.handshake {
        HStack(spacing: 6) {
          capability("Resume", enabled: handshake.supportsSessionResume)
          capability("List sessions", enabled: handshake.supportsSessionList)
          capability("Close", enabled: handshake.supportsSessionClose)
          capability("Delete", enabled: handshake.supportsSessionDelete)
          capability("Logout", enabled: handshake.supportsLogout)
        }
      } else {
        Text("Adapter capabilities are unavailable until inspect succeeds")
          .scaledFont(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var authenticationText: String {
    guard let handshake = detail.handshake else { return "Unknown" }
    guard !handshake.authMethodIds.isEmpty else { return "No methods reported" }
    return handshake.authMethodIds.joined(separator: ", ")
  }

  private func failureText(_ failure: AgentTurnFailure) -> String {
    let category = failure.category.rawValue.replacingOccurrences(of: "_", with: " ")
    return "\(category): \(failure.detail.withoutTrailingPeriod)"
  }

  private func fact(_ title: String, _ value: String) -> some View {
    GridRow {
      Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
      Text(value.withoutTrailingPeriod)
        .textSelection(.enabled)
        .gridColumnAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scaledFont(.callout)
  }

  private func capability(_ title: String, enabled: Bool) -> some View {
    Label(title, systemImage: enabled ? "checkmark.circle.fill" : "minus.circle")
      .labelStyle(.titleAndIcon)
      .scaledFont(.caption)
      .foregroundStyle(enabled ? HarnessMonitorTheme.success : .secondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(.quaternary, in: Capsule())
  }
}

struct DashboardAcpIssues: View {
  let issues: [String]

  var body: some View {
    ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
      Label(issue.withoutTrailingPeriod, systemImage: "exclamationmark.triangle.fill")
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.danger)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          HarnessMonitorTheme.danger.opacity(0.08),
          in: RoundedRectangle(cornerRadius: 10)
        )
    }
  }
}

struct DashboardAcpPermissionCard: View {
  @Bindable var store: HarnessMonitorStore
  let batch: AcpPermissionBatch
  let isBusy: Bool
  let onResolve: (AcpPermissionBatch, AcpPermissionDecision) -> Void

  private var payload: AcpPermissionDecisionPayload {
    store.acpPermissionDecisionPayload(for: batch)
  }

  private var resolutionState: BatchResolutionState {
    store.acpPermissionResolutionState(for: payload.decisionID) ?? payload.defaultResolutionState
  }

  var body: some View {
    let actions = payload.suggestedActions()
    DashboardAcpSection(title: permissionTitle) {
      Text("This request remains pending until the daemon accepts a resolution")
        .scaledFont(.callout)
        .foregroundStyle(.secondary)
      AcpPermissionDeadlineStatusView(
        payload: payload,
        lastMessageAt: store.acpPermissionLastSignalAt(sessionID: batch.sessionId),
        style: .detail,
        accessibilityIdentifier: "dashboard.acp.permission.deadline",
        referenceDate: nil
      )
      AcpPermissionDecisionPanel(
        payload: payload,
        resolutionState: resolutionState,
        isResolving: isBusy,
        selectionSummaryAccessibilityID: "dashboard.acp.permission.selection",
        panelAccessibilityID: "dashboard.acp.permission.panel",
        requestAccessibilityID: { "dashboard.acp.permission.\($0)" },
        onSelectionChanged: { requestID, isSelected in
          store.setAcpPermissionRequestSelection(
            decisionID: payload.decisionID,
            requestID: requestID,
            isSelected: isSelected
          )
        }
      )
      HStack {
        Spacer()
        ForEach(actions) { action in
          Button(
            action.title,
            role: AcpPermissionDecisionActionID.isDenyAction(action.id) ? .destructive : nil
          ) {
            resolve(action.id)
          }
          .disabled(
            isBusy || payload.isActionDisabled(action.id, resolutionState: resolutionState)
          )
          .dashboardPrimaryDecisionActionFocus(
            store: store,
            decisionID: payload.decisionID,
            isPrimaryAction: action.id
              == DashboardDecisionActionFocusPolicy.primaryActionID(in: actions)
          )
        }
      }
    }
    .id(payload.decisionID)
  }

  private var permissionTitle: String {
    batch.requests.count == 1 ? "Permission request" : "Permission requests"
  }

  private func resolve(_ actionID: String) {
    guard
      let result = try? payload.actionDecision(
        for: actionID,
        resolutionState: resolutionState
      )
    else { return }
    onResolve(batch, result.decision)
  }
}

struct DashboardAcpTranscript: View {
  let entries: [TimelineEntry]

  var body: some View {
    DashboardAcpSection(title: "Transcript") {
      if entries.isEmpty {
        Text("No transcript updates are available for this managed agent")
          .foregroundStyle(.secondary)
      } else {
        ForEach(Array(entries.suffix(20))) { entry in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(entry.kind.replacingOccurrences(of: "_", with: " ").capitalized)
                .scaledFont(.caption.weight(.medium))
              Spacer()
              Text(entry.recordedAt)
                .scaledFont(.caption2)
                .foregroundStyle(.tertiary)
            }
            Text(entry.summary.withoutTrailingPeriod)
              .textSelection(.enabled)
          }
          .padding(.vertical, 5)
          if entry.id != entries.suffix(20).last?.id { Divider() }
        }
      }
    }
  }
}

struct DashboardAcpProviderSessions: View {
  let agentID: String
  let detail: DashboardAcpAgentDetail
  let activeAction: String?
  let onClose: (String) -> Void
  let onDelete: (String) -> Void

  var body: some View {
    DashboardAcpSection(title: "Provider sessions") {
      if detail.handshake == nil {
        Text("Provider session capabilities are unavailable")
          .foregroundStyle(.secondary)
      } else if detail.handshake?.supportsSessionList != true {
        Text("This adapter does not support provider session lists")
          .foregroundStyle(.secondary)
      } else if detail.providerSessions.isEmpty {
        Text("The provider reported no sessions for this worktree")
          .foregroundStyle(.secondary)
      } else {
        ForEach(detail.providerSessions) { session in
          HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
              Text(sessionTitle(session))
                .scaledFont(.body.weight(.medium))
              Text(session.cwd)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
              if let updatedAt = session.updatedAt {
                Text("Updated \(updatedAt)")
                  .scaledFont(.caption2)
                  .foregroundStyle(.tertiary)
              }
            }
            Spacer()
            if detail.handshake?.supportsSessionClose == true {
              Button("Close") { onClose(session.sessionID) }
                .disabled(activeAction != nil)
            }
            if detail.handshake?.supportsSessionDelete == true {
              Button("Delete", role: .destructive) { onDelete(session.sessionID) }
                .disabled(activeAction != nil)
            }
          }
          .padding(.vertical, 5)
        }
      }
    }
  }

  private func sessionTitle(_ session: AcpProviderSession) -> String {
    guard let title = session.title, !title.isEmpty else { return session.sessionID }
    return title
  }
}
