import Foundation
import HarnessMonitorKit
import SwiftUI

struct TaskBoardApprovalGrantsView: View {
  let store: HarnessMonitorStore
  let workspace: PolicyCanvasWorkspace?
  let refreshID: TaskBoardApprovalGrantRefreshID
  let isDisabled: Bool

  @State private var approvalState = TaskBoardApprovalGrantsState()
  @Environment(TaskBoardRelativeTimeClock.self)
  private var relativeTimeClock
  @Environment(\.fontScale)
  private var fontScale

  var state: TaskBoardApprovalGrantsState { approvalState }

  private var labelFont: Font {
    HarnessMonitorTextSize.scaledFont(.callout.weight(.semibold), by: fontScale)
  }
  private var bodyFont: Font {
    HarnessMonitorTextSize.scaledFont(.callout, by: fontScale)
  }
  private var countFont: Font {
    HarnessMonitorTextSize.scaledFont(.callout.monospacedDigit(), by: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        Label("Policy approvals", systemImage: "person.badge.key.fill")
          .font(labelFont)
        Spacer(minLength: 0)
        if state.isLoading {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Loading policy approvals")
        }
        Text("\(state.grants.count) pending")
          .font(countFont)
          .foregroundStyle(.secondary)
      }
      policyContext
      if state.grants.isEmpty {
        Text(state.isLoading ? "Loading pending grants…" : "No pending approval grants")
          .font(bodyFont)
          .foregroundStyle(.secondary)
      } else {
        LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          ForEach(state.grants) { presentation in
            grantCard(presentation)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .task(id: refreshID) {
      enqueueRefresh()
    }
    .confirmationDialog(
      confirmationTitle,
      isPresented: confirmationPresented,
      presenting: state.confirmation
    ) { confirmation in
      confirmationActions(confirmation)
    } message: { confirmation in
      Text(confirmationMessage(confirmation))
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.step.policy-approvals")
  }

  @ViewBuilder private var policyContext: some View {
    if let activeCanvas {
      let hasLivePolicy = activeCanvas.liveDocument != nil
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        Image(systemName: hasLivePolicy ? "checkmark.shield.fill" : "doc.badge.clock")
          .foregroundStyle(
            hasLivePolicy ? HarnessMonitorTheme.accent : HarnessMonitorTheme.caution
          )
        Text(activeCanvas.title)
          .lineLimit(1)
        Text("rev \(activePolicyRevision)")
          .monospacedDigit()
          .foregroundStyle(.secondary)
        Text(hasLivePolicy ? "Live" : "No live policy")
          .foregroundStyle(
            hasLivePolicy ? HarnessMonitorTheme.accent : HarnessMonitorTheme.caution
          )
      }
      .font(bodyFont)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(
        "Active policy \(activeCanvas.title), revision \(activePolicyRevision), "
          + (hasLivePolicy ? "live" : "not live")
      )
    } else {
      Label("Current policy context unavailable", systemImage: "exclamationmark.triangle")
        .font(bodyFont)
        .foregroundStyle(HarnessMonitorTheme.caution)
    }
  }

  private func grantCard(_ presentation: TaskBoardApprovalGrantPresentation) -> some View {
    let grant = presentation.grant
    let isExpired = presentation.expiresAt.isPast(relativeTo: relativeTimeClock.referenceDate)
    let matchesActivePolicy = grantMatchesActivePolicy(grant)
    return VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
        VStack(alignment: .leading, spacing: 2) {
          Text(grant.boardItemId)
            .font(labelFont)
            .textSelection(.enabled)
          Text(
            "\(grant.action.rawValue.taskBoardPolicyTitle) · "
              + grant.reasonCode.rawValue.taskBoardPolicyTitle
          )
          .font(bodyFont)
          .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        Label(
          matchesActivePolicy ? "Current policy" : "Policy changed",
          systemImage: matchesActivePolicy
            ? "checkmark.shield"
            : "exclamationmark.arrow.triangle.2.circlepath"
        )
        .font(labelFont)
        .foregroundStyle(
          matchesActivePolicy ? HarnessMonitorTheme.accent : HarnessMonitorTheme.caution
        )
      }
      HStack(spacing: HarnessMonitorTheme.spacingMD) {
        Text("Canvas rev \(grant.canvasRevision)")
          .monospacedDigit()
        Text("Gate \(grant.nodeId)")
          .textSelection(.enabled)
        expiryLabel(presentation)
      }
      .font(bodyFont)
      .foregroundStyle(isExpired ? HarnessMonitorTheme.danger : .secondary)
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        Button {
          state.confirmation = .approve(grantID: grant.id)
        } label: {
          Label("Approve", systemImage: "checkmark.seal.fill")
        }
        .harnessActionButtonStyle(variant: .prominent, tint: HarnessMonitorTheme.accent)
        Button(role: .destructive) {
          state.confirmation = .reject(grantID: grant.id)
        } label: {
          Label("Reject", systemImage: "xmark.seal")
        }
        .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.danger)
        Button(role: .destructive) {
          state.confirmation = .revoke(grantID: grant.id)
        } label: {
          Label("Revoke", systemImage: "arrow.uturn.backward.circle")
        }
        .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.caution)
      }
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .disabled(isDisabled || state.activeGrantID != nil || isExpired)
    }
    .padding(HarnessMonitorTheme.spacingSM)
    .background(HarnessMonitorTheme.ink.opacity(0.04), in: .rect(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(HarnessMonitorTheme.ink.opacity(0.1))
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.step.policy-approval.\(grant.id)")
  }

  @ViewBuilder
  private func expiryLabel(_ presentation: TaskBoardApprovalGrantPresentation) -> some View {
    if let expiresAt = presentation.expiresAt {
      HStack(spacing: 3) {
        Text(expiresAt <= relativeTimeClock.referenceDate ? "Expired" : "Expires")
        Text(expiresAt, style: .relative)
      }
      .accessibilityElement(children: .combine)
    } else {
      Text("No expiry")
    }
  }

  private var activeCanvas: PolicyCanvasSummary? {
    workspace?.canvases.first { $0.canvasId == workspace?.activeCanvasId }
  }

  private var activePolicyRevision: UInt64 {
    activeCanvas?.liveDocument?.revision ?? activeCanvas?.revision ?? 0
  }

  private func grantMatchesActivePolicy(_ grant: PolicyApprovalGrant) -> Bool {
    grant.canvasId == workspace?.activeCanvasId
      && grant.canvasRevision == activePolicyRevision
      && activeCanvas?.liveDocument != nil
  }

  private var confirmationPresented: Binding<Bool> {
    Binding(
      get: { state.confirmation != nil },
      set: { if !$0 { state.confirmation = nil } }
    )
  }

  private var confirmationTitle: String {
    switch state.confirmation {
    case .approve:
      "Approve this one-shot spawn?"
    case .reject:
      "Reject this approval grant?"
    case .revoke:
      "Revoke this approval grant?"
    case nil:
      "Resolve approval grant"
    }
  }

  @ViewBuilder
  private func confirmationActions(
    _ confirmation: TaskBoardApprovalGrantsState.Confirmation
  ) -> some View {
    switch confirmation {
    case .approve(let grantID):
      Button("Approve") {
        state.confirmation = nil
        enqueueApproval(grantID: grantID)
      }
      .disabled(approvalActionIsDisabled(grantID: grantID))
    case .reject(let grantID):
      Button("Reject", role: .destructive) {
        state.confirmation = nil
        enqueueRejection(grantID: grantID)
      }
      .disabled(approvalActionIsDisabled(grantID: grantID))
    case .revoke(let grantID):
      Button("Revoke", role: .destructive) {
        state.confirmation = nil
        enqueueRevocation(grantID: grantID)
      }
      .disabled(approvalActionIsDisabled(grantID: grantID))
    }
    Button("Cancel", role: .cancel) {}
  }

  private func confirmationMessage(
    _ confirmation: TaskBoardApprovalGrantsState.Confirmation
  ) -> String {
    switch confirmation {
    case .approve:
      "Approving allows this matching policy revision to authorize one worker spawn."
    case .reject:
      "Rejecting records an explicit policy denial for this one-shot spawn request."
    case .revoke:
      "Revoking terminally invalidates this grant so it cannot authorize a worker spawn."
    }
  }

  private func approvalActionIsDisabled(grantID: String) -> Bool {
    guard let presentation = state.grants.first(where: { $0.id == grantID }) else {
      return true
    }
    return isDisabled
      || state.activeGrantID != nil
      || presentation.expiresAt.isPast(relativeTo: relativeTimeClock.referenceDate)
  }
}

extension Optional where Wrapped == Date {
  fileprivate func isPast(relativeTo referenceDate: Date) -> Bool {
    guard let self else { return false }
    return self <= referenceDate
  }
}

extension String {
  fileprivate var taskBoardPolicyTitle: String {
    replacingOccurrences(of: "_", with: " ").capitalized
  }
}
