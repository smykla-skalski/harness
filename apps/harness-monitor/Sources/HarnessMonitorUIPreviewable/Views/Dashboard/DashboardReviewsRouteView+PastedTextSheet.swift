import HarnessMonitorIntents
import HarnessMonitorKit
import SwiftUI

extension View {
  func dashboardReviewsPastedTextReviewSheet(
    state: Binding<DashboardReviewsPastedTextReviewSheetState?>,
    onApprove: @escaping ([ReviewItem]) -> Void,
    onAuto: @escaping ([ReviewItem]) -> Void,
    onSelect: @escaping (ReviewItem) -> Void,
    onCopy: @escaping (String) -> Void
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
        },
        onCopy: { text in
          onCopy(text)
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
    let dryRun = routePastedTextReviewSheet?.dryRun ?? false
    routePastedTextReviewSheet = nil
    enqueuePastedReviewApproval(items: items, dryRun: dryRun)
  }

  func autoPastedTextReviewItems(_ items: [ReviewItem]) {
    routePastedTextReviewSheet = nil
    requestAuto(items: items)
  }

  func selectPastedTextReviewItem(_ item: ReviewItem) {
    routeSelectedIDs = [item.pullRequestID]
    persistedPrimarySelectionID = item.pullRequestID
  }

  func copyPastedReviewList(_ text: String) {
    HarnessMonitorClipboard.copy(text)
    store.toast.presentSuccess("Copied pull request list")
  }

  func enqueuePastedReviewApproval(
    items: [ReviewItem],
    dryRun: Bool,
    workQueue: HarnessMonitorAsyncWorkQueue = .shared
  ) {
    let actionableItems = items.filter(\.canAttemptManualApproval)
    guard !actionableItems.isEmpty else {
      store.toast.presentWarning("No pasted pull requests can be approved")
      return
    }
    guard dryRun || store.apiClient != nil else {
      store.toast.presentWarning("Reviews API is unavailable")
      return
    }
    let targets = actionableItems.map(\.target)
    let client = store.apiClient
    let title = dryRun ? "Dry-run approval" : "Approving"
    store.toast.presentSuccess(
      "\(title) queued for \(actionableItems.count) pasted pull request(s)"
    )
    if !dryRun {
      HarnessMonitorIntentDonations.donateApprove(items: actionableItems)
    }
    workQueue.submit(
      HarnessMonitorAsyncWorkQueue.WorkItem(title: title) {
        let completion: DashboardReviewsPastedApprovalCompletion
        if dryRun {
          completion = .dryRun(targetCount: targets.count)
        } else {
          do {
            guard let client else {
              throw HarnessMonitorAPIError.server(code: 503, message: "Reviews API is unavailable")
            }
            let response = try await DashboardReviewsTimeoutRacer.race(
              timeoutSeconds: DashboardReviewsTimeoutRacer.defaultMutationTimeoutSeconds
            ) {
              try await client.approveReviews(
                request: ReviewsApproveRequest(targets: targets)
              )
            }
            completion = .success(response)
          } catch {
            completion = .failure(dashboardReviewsErrorMessage(for: error))
          }
        }
        await MainActor.run {
          handlePastedReviewApprovalCompletion(
            completion,
            title: title,
            items: actionableItems,
            client: client
          )
        }
      }
    )
  }

  private func reviewActionConfirmationButtonContent(
    _ confirmation: DashboardReviewActionConfirmation
  ) -> some View {
    Button(confirmation.confirmButtonTitle, role: confirmation.confirmRole) {
      routePendingActionConfirmation = nil
      confirmReviewAction(confirmation)
    }
  }

  private func handlePastedReviewApprovalCompletion(
    _ completion: DashboardReviewsPastedApprovalCompletion,
    title: String,
    items: [ReviewItem],
    client: (any HarnessMonitorClientProtocol)?
  ) {
    switch completion {
    case .dryRun(let targetCount):
      store.presentSuccessFeedback(
        "Dry run: would approve \(targetCount) pasted pull request(s)"
      )
    case .success(let response):
      recordReviewActionResponse(response, title: title, items: items)
      let feedback = dashboardReviewsActionFeedback(
        title: title,
        items: items,
        response: response
      )
      switch feedback.severity {
      case .success:
        store.presentSuccessFeedback(feedback.message)
      case .failure:
        store.presentFailureFeedback(feedback.message)
      case .warning, .undoable:
        store.toast.presentWarning(feedback.message)
      }
      if let client {
        scheduleAffectedRefresh(for: items, using: client)
      }
    case .failure(let message):
      recordReviewActionFailure(
        HarnessMonitorAPIError.server(code: 500, message: message),
        title: title,
        items: items
      )
      store.presentFailureFeedback(message)
    }
  }
}

private enum DashboardReviewsPastedApprovalCompletion: Sendable {
  case dryRun(targetCount: Int)
  case success(ReviewsActionResponse)
  case failure(String)
}
