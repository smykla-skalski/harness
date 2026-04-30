import HarnessMonitorKit
import SwiftUI

struct AcpPermissionModal: View {
  @Bindable var store: HarnessMonitorStore
  let batch: AcpPermissionBatch
  @Environment(\.openWindow)
  private var openWindow

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
      ) { _, _ in }

      Divider()
      actionRow
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(minWidth: 520, idealWidth: 580, maxWidth: 680)
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

  @ViewBuilder private var actionRow: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Button("Close") {
        store.presentingAcpPermissionBatch = nil
      }
      .keyboardShortcut(payload.isRenderable ? .cancelAction : .defaultAction)
      .disabled(isResolving)
      .accessibilityIdentifier(HarnessMonitorAccessibility.acpPermissionModalClose)
      Spacer()
      if payload.isRenderable {
        Button("Review in Decisions") {
          store.supervisorSelectedDecisionID = decisionID
          store.requestPrimaryDecisionActionFocus(decisionID: decisionID)
          openWindow(id: HarnessMonitorWindowID.decisions)
        }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier(HarnessMonitorAccessibility.acpPermissionModalOpenDecisions)
      }
    }
  }
}
