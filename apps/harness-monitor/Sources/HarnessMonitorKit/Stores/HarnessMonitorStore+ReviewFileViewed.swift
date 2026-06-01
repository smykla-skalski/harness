import Foundation

extension HarnessMonitorStore {
  /// Optimistically flip the cached viewed state for one file and queue
  /// a debounced batch mutation against the daemon. Multiple toggles
  /// within `ReviewFilesViewedDebounce` (default 250ms) coalesce
  /// into one daemon round-trip so end-of-review marking many files
  /// doesn't burn mutation rate-limit budget.
  public func setFileViewed(
    pullRequestID: String,
    path: String,
    viewed: Bool
  ) {
    let viewModel = self.viewModel(forPullRequest: pullRequestID)
    let nextState: ReviewFileViewedState = viewed ? .viewed : .unviewed
    viewModel.setViewedState(path: path, state: nextState)
    appendPendingViewed(
      pullRequestID: pullRequestID,
      path: path,
      state: nextState
    )
    scheduleViewedFlush(pullRequestID: pullRequestID)
  }

  /// Force-flush any pending debounced viewed-state mutations. Used by
  /// tests and the dashboard refresh path.
  public func flushPendingViewedMutations(pullRequestID: String) async {
    dependencyFilesViewedBatchTasks[pullRequestID]?.cancel()
    dependencyFilesViewedBatchTasks.removeValue(forKey: pullRequestID)
    await runViewedFlush(pullRequestID: pullRequestID)
  }

  // MARK: - Internals

  public static var dependencyFilesViewedDebounceNanoseconds: UInt64 { 250_000_000 }

  private func appendPendingViewed(
    pullRequestID: String,
    path: String,
    state: ReviewFileViewedState
  ) {
    var pending = dependencyFilesViewedPending[pullRequestID] ?? [:]
    pending[path] = state
    dependencyFilesViewedPending[pullRequestID] = pending
  }

  private func scheduleViewedFlush(pullRequestID: String) {
    dependencyFilesViewedBatchTasks[pullRequestID]?.cancel()
    let debounce = Self.dependencyFilesViewedDebounceNanoseconds
    dependencyFilesViewedBatchTasks[pullRequestID] = Task { [weak self] in
      try? await Task.sleep(nanoseconds: debounce)
      guard !Task.isCancelled else { return }
      await self?.runViewedFlush(pullRequestID: pullRequestID)
    }
  }

  private func runViewedFlush(pullRequestID: String) async {
    dependencyFilesViewedBatchTasks.removeValue(forKey: pullRequestID)
    guard let pending = dependencyFilesViewedPending.removeValue(forKey: pullRequestID),
      !pending.isEmpty
    else { return }
    let viewModel = self.viewModel(forPullRequest: pullRequestID)
    guard let client else { return }
    let targets: [ReviewFilesViewedTarget] = pending.map { path, state in
      ReviewFilesViewedTarget(
        path: path,
        expectedPriorState: viewModel.viewedByPath[path] ?? .unviewed,
        markViewed: state == .viewed
      )
    }
    let request = ReviewsFilesViewedRequest(
      pullRequestID: pullRequestID,
      paths: targets
    )
    do {
      let response = try await client.viewedReviewFiles(request: request)
      for result in response.results {
        viewModel.setViewedState(path: result.path, state: result.viewerViewedState)
      }
    } catch {
      // Roll back optimistic flips on failure so the UI doesn't lie about
      // the daemon-confirmed state. The user can retry from the toolbar.
      for (path, _) in pending {
        viewModel.setViewedState(path: path, state: .unviewed)
      }
      presentFailureFeedback(error.localizedDescription, rollupDuplicates: true)
    }
  }
}
