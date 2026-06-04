import HarnessMonitorKit
import SwiftUI

extension DashboardReviewsRouteView {
  var reviewCommandFocus: DashboardReviewsCommandFocus {
    let commandItems = selectedItems
    let primaryItem = primaryDetailItem
    let pinSelectionTitle = pinSelectionMenuTitle(for: commandItems)
    return DashboardReviewsCommandFocus(
      selectionCount: commandItems.count,
      hasProblemChecksFilter: showsProblemChecksOnly,
      canApprove: commandItems.contains(where: { $0.canAttemptManualApproval }),
      canMerge: commandItems.contains(where: { $0.canAttemptManualMerge }),
      canRerunChecks: commandItems.contains(where: { $0.canAttemptRerunChecks }),
      canOpenPullRequest: primaryItem != nil,
      canCopyDiagnostics: primaryItem != nil,
      canTogglePinSelection: !commandItems.isEmpty,
      pinSelectionTitle: pinSelectionTitle,
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
      togglePinSelection: {
        togglePinnedSelection(items: commandItems)
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
