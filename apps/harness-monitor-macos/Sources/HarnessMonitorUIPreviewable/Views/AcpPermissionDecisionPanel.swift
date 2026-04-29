import HarnessMonitorKit
import SwiftUI

struct AcpPermissionDecisionPanel: View {
  let payload: AcpPermissionDecisionPayload
  let resolutionState: BatchResolutionState
  let isResolving: Bool
  let selectionSummaryAccessibilityID: String
  let panelAccessibilityID: String
  let requestAccessibilityID: (String) -> String
  let onSelectionChanged: ((String, Bool) -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      if let error = payload.renderError {
        AcpPermissionDecisionErrorView(error: error)
          .accessibilityIdentifier(HarnessMonitorAccessibility.decisionAcpError)
      } else if let batch = payload.renderableBatch {
        let selectionSummary = payload.selectionSummary(resolutionState: resolutionState)
        Text(selectionSummary)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(selectionSummary)
          .accessibilityTestProbe(
            selectionSummaryAccessibilityID,
            label: selectionSummary
          )
        if isResolving {
          Text("Submitting permission decision...")
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .accessibilityLabel("Submitting permission decision")
        }
        ScrollView {
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
            ForEach(batch.requests) { request in
              Toggle(
                isOn: selectionBinding(for: request.id)
              ) {
                VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
                  Text(request.title)
                    .scaledFont(.body.weight(.medium))
                  Text(request.detail)
                    .scaledFont(.caption)
                    .foregroundStyle(HarnessMonitorTheme.secondaryInk)
                    .lineLimit(3)
                  Text(request.breadcrumb)
                    .scaledFont(.caption2)
                    .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
                    .lineLimit(1)
                }
              }
              .toggleStyle(.checkbox)
              .disabled(isResolving || onSelectionChanged == nil)
              .accessibilityIdentifier(requestAccessibilityID(request.id))
              .accessibilityLabel(request.title)
              .accessibilityHint(accessibilityHint(for: request))
            }
          }
        }
        .frame(maxHeight: 220)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(panelAccessibilityID)
  }

  private func selectionBinding(for requestID: String) -> Binding<Bool> {
    Binding {
      resolutionState.isSelected(requestID: requestID)
    } set: { isSelected in
      onSelectionChanged?(requestID, isSelected)
    }
  }

  private func accessibilityHint(
    for request: AcpPermissionDecisionPayload.RenderableBatch.Request
  ) -> String {
    [request.detail, request.breadcrumb]
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: ". ")
  }
}

private struct AcpPermissionDecisionErrorView: View {
  let error: RenderableError

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(error.title)
        .scaledFont(.body.weight(.semibold))
      Text(error.message)
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      if let recoverySuggestion = error.recoverySuggestion {
        Text(recoverySuggestion)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
    }
    .padding(HarnessMonitorTheme.spacingMD)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD))
  }
}
