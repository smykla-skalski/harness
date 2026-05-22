import Foundation

/// Compound key the store uses to dedupe in-flight list fetches across a
/// (pullRequestID, headRefOid) pair. A force-push that flips the head
/// gets a fresh key so the new fetch is not blocked by the old one.
public struct ReviewFilesFetchKey: Hashable, Sendable {
  public let pullRequestID: String
  public let headRefOid: String

  public init(pullRequestID: String, headRefOid: String) {
    self.pullRequestID = pullRequestID
    self.headRefOid = headRefOid
  }
}

extension HarnessMonitorStore {
  /// Lazily return (and cache) the per-PR view model for the Files
  /// section. Lifecycle is owned by the store; the view layer reads via
  /// this accessor and never invalidates other PRs' views by touching one
  /// PR's state.
  public func viewModel(
    forPullRequest pullRequestID: String
  ) -> ReviewFilesViewModel {
    if let existing = dependencyFilesViewModels[pullRequestID] { return existing }
    let viewModel = ReviewFilesViewModel(pullRequestID: pullRequestID)
    dependencyFilesViewModels[pullRequestID] = viewModel
    return viewModel
  }

  /// Drop view models for PRs the dependencies refresh tick no longer
  /// reports. Called by the dashboard route view when the active set
  /// changes so the @ObservationIgnored map doesn't grow unbounded.
  public func releaseReviewFilesViewModels(
    retaining retainedPullRequestIDs: Set<String>
  ) {
    let toDrop = dependencyFilesViewModels.keys.filter {
      !retainedPullRequestIDs.contains($0)
    }
    for key in toDrop {
      dependencyFilesViewModels.removeValue(forKey: key)
      dependencyFilesViewedBatchTasks[key]?.cancel()
      dependencyFilesViewedBatchTasks.removeValue(forKey: key)
      dependencyFilesViewedPending.removeValue(forKey: key)
    }
  }

  /// Prepare the metadata fetch for a PR's files. Cache-first: if the
  /// view model already has `state == .loaded`, this is a no-op unless
  /// `forceRefresh: true` is set.
  public func prepareReviewFiles(
    pullRequestID: String,
    forceRefresh: Bool = false
  ) async {
    let viewModel = self.viewModel(forPullRequest: pullRequestID)
    if !forceRefresh, case .loaded = viewModel.state { return }
    let fetchKey = ReviewFilesFetchKey(
      pullRequestID: pullRequestID,
      headRefOid: viewModel.headRefOid
    )
    guard !reviewFilesPendingFetches.contains(fetchKey) else { return }
    reviewFilesPendingFetches.insert(fetchKey)
    viewModel.setLoading()
    defer { reviewFilesPendingFetches.remove(fetchKey) }
    let interval = ReviewFilesPerf.beginMetadataFetch(pullRequestID: pullRequestID)
    defer { ReviewFilesPerf.end(interval) }
    do {
      let response = try await fetchListFromClient(
        pullRequestID: pullRequestID,
        forceRefresh: forceRefresh
      )
      viewModel.ingest(response: response)
    } catch {
      viewModel.setError(error.localizedDescription)
    }
  }

  /// Force-refresh wrapper used by the UI's pull-to-refresh affordance
  /// and the system-wake hook.
  public func refreshReviewFiles(pullRequestID: String) async {
    await prepareReviewFiles(pullRequestID: pullRequestID, forceRefresh: true)
  }

  // MARK: - Internals

  private func fetchListFromClient(
    pullRequestID: String,
    forceRefresh: Bool
  ) async throws -> ReviewsFilesListResponse {
    guard let client else {
      throw HarnessMonitorAPIError.server(
        code: 503,
        message: "Daemon client not available for review files"
      )
    }
    let request = ReviewsFilesListRequest(
      pullRequestID: pullRequestID,
      forceRefresh: forceRefresh
    )
    return try await client.listReviewFiles(request: request)
  }
}
