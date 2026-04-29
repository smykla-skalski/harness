import HarnessMonitorKit
import SwiftUI

struct AcpPermissionDecisionDetailView: View {
  let payload: AcpPermissionDecisionPayload
  let store: HarnessMonitorStore?

  var body: some View {
    if let store {
      InteractiveAcpPermissionDecisionDetailView(
        payload: payload,
        store: store
      )
    } else {
      AcpPermissionDecisionDetailContent(
        payload: payload,
        resolutionState: payload.defaultResolutionState,
        isResolving: false,
        onSelectionChanged: nil
      )
    }
  }
}

private struct InteractiveAcpPermissionDecisionDetailView: View {
  let payload: AcpPermissionDecisionPayload
  @Bindable var store: HarnessMonitorStore

  var body: some View {
    let resolutionState = store.acpPermissionResolutionState(for: payload.decisionID)
      ?? payload.defaultResolutionState
    AcpPermissionDecisionDetailContent(
      payload: payload,
      resolutionState: resolutionState,
      isResolving: resolutionState.isSubmitting
        || store.resolvingAcpPermissionBatchID == payload.rawBatch.batchId
    ) { requestID, isSelected in
      store.setAcpPermissionRequestSelection(
        decisionID: payload.decisionID,
        requestID: requestID,
        isSelected: isSelected
      )
    }
  }
}

private struct AcpPermissionDecisionDetailContent: View {
  let payload: AcpPermissionDecisionPayload
  let resolutionState: BatchResolutionState
  let isResolving: Bool
  let onSelectionChanged: ((String, Bool) -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      Text("Agent permission request")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text("Review the requested tool actions and choose what to allow before the agent continues.")
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)

      AcpPermissionDecisionPanel(
        payload: payload,
        resolutionState: resolutionState,
        isResolving: isResolving,
        selectionSummaryAccessibilityID: HarnessMonitorAccessibility.decisionAcpSelectionSummary,
        panelAccessibilityID: HarnessMonitorAccessibility.decisionAcpPanel,
        requestAccessibilityID: HarnessMonitorAccessibility.decisionAcpRequest,
        onSelectionChanged: onSelectionChanged
      )
    }
  }
}
