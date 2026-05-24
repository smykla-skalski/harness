import Foundation

public enum ReviewReviewThreadResolveOutcome: Sendable, Equatable {
  case resolved(threadID: String, isResolved: Bool)
  case failed(reason: String)
  case daemonOffline
}

extension HarnessMonitorStore {
  /// Toggle a review thread's `isResolved` state on GitHub. Mirrors the
  /// comment-post optimistic-insert pattern from
  /// `postReviewComment`: mutate the in-memory entry FIRST so
  /// the UI reflects the user's action without lag, then reconcile
  /// against the daemon's echoed `isResolved` value on success or
  /// revert on failure.
  public func setReviewThreadResolved(
    threadID: String,
    pullRequestID: String,
    desired: Bool
  ) async -> ReviewReviewThreadResolveOutcome {
    guard let client else {
      return .daemonOffline
    }
    let viewModel = reviewTimelineViewModel(for: pullRequestID)
    // Snapshot the prior state so we can revert on failure.
    let priorState = viewModel.threadResolvedState(threadID: threadID)
    viewModel.updateReviewThreadResolved(threadID: threadID, resolved: desired)
    do {
      let response = try await client.setReviewThreadResolved(
        request: ReviewsReviewThreadResolveRequest(
          threadId: threadID,
          resolved: desired,
          pullRequestId: pullRequestID
        )
      )
      // Reconcile: server-side `isResolved` is authoritative. Usually
      // matches `desired`, but if a concurrent toggle from another
      // viewer landed first the daemon's value differs — surface that.
      if response.resolved != desired {
        viewModel.updateReviewThreadResolved(
          threadID: threadID,
          resolved: response.resolved
        )
      }
      return .resolved(threadID: threadID, isResolved: response.resolved)
    } catch {
      // Revert the optimistic toggle when the daemon round-trip fails.
      if let prior = priorState {
        viewModel.updateReviewThreadResolved(threadID: threadID, resolved: prior)
      }
      return .failed(reason: error.localizedDescription)
    }
  }
}
