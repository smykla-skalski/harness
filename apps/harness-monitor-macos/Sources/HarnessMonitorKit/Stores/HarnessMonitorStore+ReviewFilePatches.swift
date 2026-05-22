import Foundation

extension HarnessMonitorStore {
  /// Fetch the patches for the supplied paths and store them on the
  /// per-PR view model. Paths already cached as `.loaded` are skipped.
  /// Drift is detected on the daemon's side; when present we evict the
  /// view model's patches and re-issue the metadata list fetch so the
  /// UI sees the new headRefOid.
  public func preparePatches(
    forPullRequest pullRequestID: String,
    paths: [String],
    largeDiffStrategy: FilesLargeDiffStrategy? = nil
  ) async {
    let viewModel = self.viewModel(forPullRequest: pullRequestID)
    let pendingPaths = paths.filter { path in
      switch viewModel.patches[path] ?? .notLoaded {
      case .loaded: return false
      default: return true
      }
    }
    guard !pendingPaths.isEmpty else { return }
    guard let client else {
      for path in pendingPaths {
        viewModel.setPatchState(
          path: path,
          state: .failed("Daemon client not available")
        )
      }
      return
    }
    for path in pendingPaths {
      viewModel.setPatchState(path: path, state: .loading)
    }
    let request = ReviewsFilesPatchRequest(
      pullRequestID: pullRequestID,
      headRefOidExpected: viewModel.headRefOid,
      paths: pendingPaths,
      number: viewModel.number,
      repositoryFullName: viewModel.repositoryFullName,
      baseRefOidExpected: viewModel.baseRefOid,
      headRefName: viewModel.headRefName,
      baseRefName: viewModel.baseRefName,
      largeDiffStrategy: largeDiffStrategy
    )
    let interval = ReviewFilesPerf.beginPatchFetch(
      pullRequestID: pullRequestID,
      pathCount: pendingPaths.count
    )
    defer { ReviewFilesPerf.end(interval) }
    do {
      let response = try await client.patchReviewFiles(request: request)
      if response.drifted {
        viewModel.patches.removeAll()
        await refreshReviewFiles(pullRequestID: pullRequestID)
        return
      }
      let returnedPaths = Set(response.patches.map(\.path))
      for path in pendingPaths where !returnedPaths.contains(path) {
        viewModel.setPatchState(
          path: path,
          state: .failed("Daemon did not return a patch for this path")
        )
      }
      viewModel.ingest(patches: response.patches)
    } catch {
      for path in pendingPaths {
        viewModel.setPatchState(
          path: path,
          state: .failed(error.localizedDescription)
        )
      }
    }
  }
}
