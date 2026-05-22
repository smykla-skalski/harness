import HarnessMonitorKit
import SwiftUI

extension DashboardReviewsRouteView {
  var reviewCommandFocus: DashboardReviewsCommandFocus {
    let commandItems = selectedItems
    let primaryItem = primaryDetailItem
    return DashboardReviewsCommandFocus(
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

  func copyDiagnostics(for item: ReviewItem) {
    HarnessMonitorClipboard.copy(activitySnapshot(for: item).diagnosticsText)
    store.presentSuccessFeedback("Copied review diagnostics")
  }
}
