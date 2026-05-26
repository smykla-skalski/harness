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
    let candidatePaths = patchCandidatePaths(paths: paths, viewModel: viewModel)
    let cacheMissPaths = await applyCachedPatches(candidatePaths, viewModel: viewModel)
    guard !Task.isCancelled else { return }
    let pendingPaths = patchCandidatePaths(paths: cacheMissPaths, viewModel: viewModel)
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
      viewModel.noteRateLimitSnapshot(response.rateLimitSnapshot)
      viewModel.ingest(patches: response.patches)
      await persistPatchResponse(response, viewModel: viewModel)
    } catch {
      for path in pendingPaths {
        viewModel.setPatchState(
          path: path,
          state: .failed(error.localizedDescription)
        )
      }
    }
  }

  private func patchCandidatePaths(
    paths: [String],
    viewModel: ReviewFilesViewModel
  ) -> [String] {
    dedupePatchPaths(paths).filter { path in
      switch viewModel.patches[path] ?? .notLoaded {
      case .notLoaded, .failed:
        return true
      case .loading, .loaded:
        return false
      }
    }
  }

  private func applyCachedPatches(
    _ paths: [String],
    viewModel: ReviewFilesViewModel
  ) async -> [String] {
    guard !paths.isEmpty else { return [] }
    let interval = ReviewFilesPerf.beginPatchCacheRead(
      pullRequestID: viewModel.pullRequestID,
      pathCount: paths.count
    )
    defer { ReviewFilesPerf.end(interval) }

    var misses: [String] = []
    for path in paths {
      if let entry = await reviewFilePatchStore.read(
        pullRequestID: viewModel.pullRequestID,
        headRefOid: viewModel.headRefOid,
        path: path
      ) {
        viewModel.setPatchState(
          path: path,
          state: .loaded(
            ReviewFilePatch(
              path: path,
              headRefOid: viewModel.headRefOid,
              entry: entry
            )
          )
        )
      } else {
        misses.append(path)
      }
    }
    return misses
  }

  private func persistPatchResponse(
    _ response: ReviewsFilesPatchResponse,
    viewModel: ReviewFilesViewModel
  ) async {
    guard !response.patches.isEmpty else { return }
    let interval = ReviewFilesPerf.beginPatchCacheStore(
      pullRequestID: viewModel.pullRequestID,
      pathCount: response.patches.count
    )
    defer { ReviewFilesPerf.end(interval) }
    for patch in response.patches {
      await reviewFilePatchStore.store(
        pullRequestID: viewModel.pullRequestID,
        headRefOid: viewModel.headRefOid,
        path: patch.path,
        entry: ReviewFilePatchStore.Entry(patch: patch)
      )
    }
  }

  private func dedupePatchPaths(_ paths: [String]) -> [String] {
    var seen: Set<String> = []
    var out: [String] = []
    for path in paths where seen.insert(path).inserted {
      out.append(path)
    }
    return out
  }
}

extension ReviewFilePatch {
  fileprivate init(
    path: String,
    headRefOid: String,
    entry: ReviewFilePatchStore.Entry
  ) {
    self.init(
      path: path,
      patch: entry.patch,
      status: entry.status,
      additions: entry.additions,
      deletions: entry.deletions,
      truncated: entry.truncated,
      etag: entry.etag,
      servedBy: entry.servedBy,
      fetchedAt: entry.fetchedAt,
      headRefOid: headRefOid
    )
  }
}

extension ReviewFilePatchStore.Entry {
  fileprivate init(patch: ReviewFilePatch) {
    self.init(
      patch: patch.patch,
      etag: patch.etag,
      additions: patch.additions,
      deletions: patch.deletions,
      truncated: patch.truncated,
      status: patch.status,
      servedBy: patch.servedBy,
      fetchedAt: patch.fetchedAt
    )
  }
}
