import Foundation

public struct PendingReviewBodyEdit: Sendable {
  public let snapshotPriorBody: String
  public let task: Task<Void, Never>
}

extension HarnessMonitorStore {
  /// Default debounce window for coalescing rapid checkbox clicks before
  /// posting a single daemon write of the latest body state.
  public static let reviewBodyEditDebounceMillis: Int = 450

  /// Optimistically swap the local body state to `newBody` immediately,
  /// but coalesce rapid follow-up edits into a single debounced daemon
  /// write of the most recent body. The hash basis used for the write is
  /// the `priorBody` from the first click in the burst, so concurrent
  /// upstream edits are still detected via `bodyDrifted`.
  public func coalesceReviewBodyEdit(
    pullRequestID id: String,
    newBody: String,
    priorBody: String,
    debounceMillis: Int? = nil,
    completion: @MainActor @escaping (ReviewBodySetOutcome) -> Void = { _ in }
  ) {
    let priorEntry = reviewBodies.cached(forPullRequestID: id)
    reviewBodyState[id] = .loaded(newBody)
    if let priorEntry {
      reviewBodies.store(
        pullRequestID: id,
        body: newBody,
        prUpdatedAt: priorEntry.prUpdatedAt,
        fetchedAt: priorEntry.fetchedAt
      )
    }

    let snapshot: String
    if let existing = pendingReviewBodyEdits[id] {
      existing.task.cancel()
      snapshot = existing.snapshotPriorBody
    } else {
      snapshot = priorBody
    }

    let delay = debounceMillis ?? Self.reviewBodyEditDebounceMillis
    let task = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
      guard !Task.isCancelled, let self else { return }
      guard case .loaded(let latest) = self.reviewBodyState[id] else {
        self.pendingReviewBodyEdits[id] = nil
        return
      }
      self.pendingReviewBodyEdits[id] = nil
      let outcome = await self.setReviewBody(
        pullRequestID: id,
        newBody: latest,
        priorBody: snapshot
      )
      completion(outcome)
    }

    pendingReviewBodyEdits[id] = PendingReviewBodyEdit(
      snapshotPriorBody: snapshot,
      task: task
    )
  }
}
