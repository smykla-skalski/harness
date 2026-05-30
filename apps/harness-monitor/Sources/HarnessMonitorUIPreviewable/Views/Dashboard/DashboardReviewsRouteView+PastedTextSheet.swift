import HarnessMonitorKit
import SwiftUI

extension View {
  func dashboardReviewsPastedTextReviewSheet(
    state: Binding<DashboardReviewsPastedTextReviewSheetState?>,
    onApprove: @escaping ([ReviewItem]) -> Void,
    onAuto: @escaping ([ReviewItem]) -> Void,
    onSelect: @escaping (ReviewItem) -> Void
  ) -> some View {
    sheet(item: state) { sheetState in
      DashboardReviewsPastedTextReviewSheet(
        state: sheetState,
        onApprove: { items in
          onApprove(items)
        },
        onAuto: { items in
          onAuto(items)
        },
        onSelect: { item in
          onSelect(item)
        }
      )
    }
  }
}

extension DashboardReviewsRouteView {
  @ViewBuilder
  func reviewActionConfirmationButton(
    _ confirmation: DashboardReviewActionConfirmation
  ) -> some View {
    if confirmation.action == .approve {
      reviewActionConfirmationButtonContent(confirmation)
        .keyboardShortcut(.defaultAction)
    } else {
      reviewActionConfirmationButtonContent(confirmation)
    }
  }

  func approvePastedTextReviewItems(_ items: [ReviewItem]) {
    routePastedTextReviewSheet = nil
    trackInFlight(Task { await performReviewAction(.approve, items: items) })
  }

  func autoPastedTextReviewItems(_ items: [ReviewItem]) {
    routePastedTextReviewSheet = nil
    requestAuto(items: items)
  }

  func selectPastedTextReviewItem(_ item: ReviewItem) {
    routeSelectedIDs = [item.pullRequestID]
    persistedPrimarySelectionID = item.pullRequestID
  }

  private func reviewActionConfirmationButtonContent(
    _ confirmation: DashboardReviewActionConfirmation
  ) -> some View {
    Button(confirmation.confirmButtonTitle, role: confirmation.confirmRole) {
      routePendingActionConfirmation = nil
      confirmReviewAction(confirmation)
    }
  }
}
