import HarnessMonitorKit
import SwiftUI

extension View {
  func dashboardReviewsTextPasteSheetHost(
    store: HarnessMonitorStore,
    history: GlobalWindowNavigationHistory
  ) -> some View {
    modifier(DashboardReviewsTextPasteSheetHost(store: store, history: history))
  }
}

@MainActor
struct DashboardReviewsTextPasteSheetHost: ViewModifier {
  let store: HarnessMonitorStore
  let history: GlobalWindowNavigationHistory

  @Environment(\.openAnythingDashboardReviewRegistry)
  var openAnythingReviews
  @AppStorage(DashboardReviewsPreferences.storageKey)
  var storedPreferences = ""
  @State private var handledTextPasteRequestID = 0
  @State private var pastedTextReviewSheet: DashboardReviewsPastedTextReviewSheetState?
  @State private var textPasteTask: Task<Void, Never>?

  func body(content: Content) -> some View {
    content
      .dashboardReviewsPastedTextReviewSheet(
        state: $pastedTextReviewSheet,
        onApprove: approvePastedTextReviewItems,
        onAuto: autoPastedTextReviewItems,
        onSelect: selectPastedTextReviewItem,
        onCopy: copyPastedReviewList
      )
      .onAppear {
        consumePendingReviewTextPasteRequest()
      }
      .onReceive(
        NotificationCenter.default.publisher(
          for: DashboardReviewsTextPasteboardRequests.changedNotification
        )
      ) { _ in
        consumePendingReviewTextPasteRequest()
      }
      .onDisappear {
        textPasteTask?.cancel()
        textPasteTask = nil
      }
  }

  private func consumePendingReviewTextPasteRequest() {
    guard
      let request = DashboardReviewsTextPasteboardRequests.takePendingRequest(
        after: handledTextPasteRequestID
      )
    else {
      return
    }
    handledTextPasteRequestID = request.id
    textPasteTask?.cancel()
    textPasteTask = Task { await handlePastedReviewText(request.text) }
  }

  func currentPastedTextReviewSheetDryRun() -> Bool {
    pastedTextReviewSheet?.dryRun ?? false
  }

  func presentPastedTextReviewSheet(_ state: DashboardReviewsPastedTextReviewSheetState) {
    pastedTextReviewSheet = state
  }

  func clearPastedTextReviewSheet() {
    pastedTextReviewSheet = nil
  }
}
