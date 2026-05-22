import Foundation

/// View-facing state of a dependency-update PR body fetch keyed by
/// pull-request id. Drives the Description section in the Reviews
/// detail pane.
public enum ReviewBodyState: Equatable, Sendable {
  case loading
  case loaded(String)
  case failed(String)
}

/// Identity used by SwiftUI `.task(id:)` to drive the description fetch.
/// Re-fires when the visible PR changes or when the daemon comes back online,
/// so a `.failed("Daemon unavailable")` state recovers automatically without
/// the user having to navigate away and back.
public struct ReviewBodyTaskKey: Hashable, Sendable {
  public let pullRequestID: String
  public let prUpdatedAt: String
  public let isDaemonOnline: Bool

  public init(item: ReviewItem, isDaemonOnline: Bool) {
    self.pullRequestID = item.pullRequestID
    self.prUpdatedAt = item.updatedAt
    self.isDaemonOnline = isDaemonOnline
  }
}

extension HarnessMonitorStore {
  /// Ensure the description body for `item` is loaded into
  /// `reviewBodyState`. Returns immediately when a fresh entry is
  /// cached (relative to `item.updatedAt`); otherwise marks state as
  /// `.loading`, fetches via the client, persists to disk, and publishes
  /// `.loaded` or `.failed`.
  ///
  /// Concurrent calls for the same pull request id collapse to a single
  /// in-flight fetch.
  public func prepareReviewBody(for item: ReviewItem) async {
    let id = item.pullRequestID
    if let entry = reviewBodies.cached(forPullRequestID: id, since: item.updatedAt) {
      reviewBodyState[id] = .loaded(entry.body)
      return
    }
    if pendingReviewBodyFetches.contains(id) {
      return
    }
    pendingReviewBodyFetches.insert(id)
    reviewBodyState[id] = .loading
    defer { pendingReviewBodyFetches.remove(id) }

    guard let client else {
      reviewBodyState[id] = .failed("Daemon unavailable")
      return
    }

    do {
      let response = try await client.fetchReviewBody(
        request: ReviewsBodyRequest(pullRequestID: id)
      )
      reviewBodies.store(
        pullRequestID: response.pullRequestID,
        body: response.body,
        prUpdatedAt: response.prUpdatedAt,
        fetchedAt: response.fetchedAt
      )
      reviewBodyState[id] = .loaded(response.body)
    } catch {
      reviewBodyState[id] = .failed(error.localizedDescription)
    }
  }

  /// Push an edited dependency-update PR body through the daemon and refresh
  /// the local body cache with the daemon-confirmed current body.
  @discardableResult
  public func updateReviewBody(
    pullRequestID: String,
    expectedPriorBodySHA256: String,
    newBody: String
  ) async -> ReviewsBodyUpdateResponse? {
    guard let client else {
      reviewBodyState[pullRequestID] = .failed("Daemon unavailable")
      return nil
    }
    do {
      let response = try await client.updateReviewBody(
        request: ReviewsBodyUpdateRequest(
          pullRequestID: pullRequestID,
          expectedPriorBodySHA256: expectedPriorBodySHA256,
          newBody: newBody
        )
      )
      reviewBodies.store(
        pullRequestID: response.pullRequestID,
        body: response.currentBody,
        prUpdatedAt: response.prUpdatedAt,
        fetchedAt: response.fetchedAt
      )
      reviewBodyState[response.pullRequestID] = .loaded(response.currentBody)
      return response
    } catch {
      reviewBodyState[pullRequestID] = .failed(error.localizedDescription)
      return nil
    }
  }
}
