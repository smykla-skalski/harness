import Foundation
import HarnessMonitorIntents
import HarnessMonitorKit

extension DashboardReviewsTextPasteSheetHost {
  func approvePastedTextReviewItems(_ items: [ReviewItem]) {
    let dryRun = currentPastedTextReviewSheetDryRun()
    clearPastedTextReviewSheet()
    enqueuePastedReviewApproval(items: items, dryRun: dryRun)
  }

  func autoPastedTextReviewItems(_ items: [ReviewItem]) {
    clearPastedTextReviewSheet()
    guard let firstItem = items.first else { return }
    openAnythingReviews.requestSelection(pullRequestID: firstItem.pullRequestID)
    UserDefaults.standard.set(
      DashboardWindowRoute.reviews.rawValue,
      forKey: DashboardRouteRestorationDefaults.storageKey
    )
    history.requestDashboardRoute(.reviews)
    store.toast.presentWarning("Open Reviews to start the auto policy")
  }

  func selectPastedTextReviewItem(_ item: ReviewItem) {
    openAnythingReviews.requestSelection(pullRequestID: item.pullRequestID)
    UserDefaults.standard.set(
      DashboardWindowRoute.reviews.rawValue,
      forKey: DashboardRouteRestorationDefaults.storageKey
    )
    history.requestDashboardRoute(.reviews)
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
        let completion: DashboardReviewsTextPasteHostApprovalCompletion
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
                request: ReviewsApproveRequest(targets: targets, source: .reviewTextPaste)
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
            items: actionableItems
          )
        }
      }
    )
  }

  private func handlePastedReviewApprovalCompletion(
    _ completion: DashboardReviewsTextPasteHostApprovalCompletion,
    title: String,
    items: [ReviewItem]
  ) {
    switch completion {
    case .dryRun(let targetCount):
      store.presentSuccessFeedback(
        "Dry run: would approve \(targetCount) pasted pull request(s)"
      )
    case .success(let response):
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
      case .warning, .undoable, .activity:
        store.toast.presentWarning(feedback.message)
      }
    case .failure(let message):
      store.presentFailureFeedback(message)
    }
  }
}

private enum DashboardReviewsTextPasteHostApprovalCompletion: Sendable {
  case dryRun(targetCount: Int)
  case success(ReviewsActionResponse)
  case failure(String)
}
