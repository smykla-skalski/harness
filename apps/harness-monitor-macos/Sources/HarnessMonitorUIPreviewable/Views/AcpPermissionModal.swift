import HarnessMonitorKit
import SwiftUI

struct AcpPermissionModal: View {
  @Bindable var store: HarnessMonitorStore
  let batch: AcpPermissionBatch

  private var payload: AcpPermissionDecisionPayload {
    store.acpPermissionDecisionPayload(for: batch)
  }

  private var decisionID: String {
    payload.decisionID
  }

  private var resolutionState: BatchResolutionState {
    store.acpPermissionResolutionState(for: decisionID) ?? payload.defaultResolutionState
  }

  private var isResolving: Bool {
    resolutionState.isSubmitting || store.resolvingAcpPermissionBatchID == batch.batchId
  }

  private var selectionSummary: String {
    payload.selectionSummary(resolutionState: resolutionState)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      Text(title)
        .scaledFont(.title3.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
      Text(payload.summary)
        .scaledFont(.body)
        .accessibilityLabel(payload.summary)

      AcpPermissionDecisionPanel(
        payload: payload,
        resolutionState: resolutionState,
        isResolving: isResolving,
        selectionSummaryAccessibilityID: HarnessMonitorAccessibility
          .acpPermissionModalSelectionSummary,
        panelAccessibilityID: HarnessMonitorAccessibility.acpPermissionModal,
        requestAccessibilityID: HarnessMonitorAccessibility.acpPermissionModalItem
      ) { requestID, isSelected in
        store.setAcpPermissionRequestSelection(
          decisionID: decisionID,
          requestID: requestID,
          isSelected: isSelected
        )
      }

      actionRow
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(width: 520)
    .onAppear {
      AccessibilityNotification.Announcement(openingAnnouncement).post()
    }
    .onChange(of: selectionSummary) { oldValue, newValue in
      guard oldValue != newValue else {
        return
      }
      AccessibilityNotification.Announcement(selectionChangeAnnouncement).post()
    }
  }

  private var title: String {
    payload.requestCount == 1 ? "Agent permission required" : "Agent permissions required"
  }

  private var openingAnnouncement: String {
    if let error = payload.renderError {
      return "\(title). \(payload.summary) \(error.message)"
    }
    return "\(title). \(payload.summary) \(selectionSummary)"
  }

  private var selectionChangeAnnouncement: String {
    "Selection updated. \(selectionSummary)"
  }

  @ViewBuilder
  private var actionRow: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      if payload.isRenderable {
        Button(payload.requestCount == 1 ? "Deny" : "Deny All") {
          resolve(
            actionID: payload.requestCount == 1
              ? AcpPermissionDecisionActionID.deny
              : AcpPermissionDecisionActionID.denyAll)
        }
        .keyboardShortcut(.cancelAction)
        .disabled(isResolving)

        Spacer()

        if payload.requestCount == 1 {
          Button("Approve") {
            resolve(actionID: AcpPermissionDecisionActionID.approve)
          }
          .keyboardShortcut(.defaultAction)
          .disabled(isResolving)
        } else {
          Button("Approve Selected") {
            resolve(actionID: AcpPermissionDecisionActionID.approveSelected)
          }
          .disabled(
            isResolving
              || payload.isActionDisabled(
                AcpPermissionDecisionActionID.approveSelected,
                resolutionState: resolutionState
              )
          )
          Button("Approve All") {
            resolve(actionID: AcpPermissionDecisionActionID.approveAll)
          }
          .keyboardShortcut(.defaultAction)
          .disabled(isResolving)
        }
      } else {
        Spacer()
        Button("Close") {
          store.presentingAcpPermissionBatch = nil
        }
        .keyboardShortcut(.defaultAction)
      }
    }
  }

  private func resolve(actionID: String) {
    Task {
      await store.submitAcpPermissionDecisionAction(
        decisionID: decisionID,
        actionID: actionID
      )
    }
  }
}
