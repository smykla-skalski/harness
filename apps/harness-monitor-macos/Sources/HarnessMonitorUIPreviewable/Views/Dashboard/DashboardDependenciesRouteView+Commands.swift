import HarnessMonitorKit
import SwiftUI

extension DashboardDependenciesRouteView {
  var dependencyCommandFocus: DashboardDependenciesCommandFocus {
    let commandItems = selectedItems
    let primaryItem = primaryDetailItem
    return DashboardDependenciesCommandFocus(
      selectionCount: commandItems.count,
      hasProblemChecksFilter: showsProblemChecksOnly,
      canApprove: commandItems.contains(where: \.canAttemptManualApproval),
      canMerge: commandItems.contains(where: \.canAttemptManualMerge),
      canRerunChecks: commandItems.contains(where: \.canAttemptRerunChecks),
      canOpenPullRequest: primaryItem != nil,
      canCopyDiagnostics: primaryItem != nil,
      approve: { requestApproveOrConfirm(items: commandItems) },
      merge: { requestMergeOrConfirm(items: commandItems) },
      rerunChecks: { trackInFlight(Task { await rerunChecks(items: commandItems) }) },
      openPullRequest: {
        if let primaryItem {
          openItem(primaryItem)
        }
      },
      copyDiagnostics: {
        if let primaryItem {
          copyDiagnostics(for: primaryItem)
        }
      },
      toggleProblemChecksFilter: {
        showsProblemChecksOnly.toggle()
      }
    )
  }

  func copyDiagnostics(for item: DependencyUpdateItem) {
    HarnessMonitorClipboard.copy(activitySnapshot(for: item).diagnosticsText)
    store.presentSuccessFeedback("Copied dependency diagnostics")
  }
}
