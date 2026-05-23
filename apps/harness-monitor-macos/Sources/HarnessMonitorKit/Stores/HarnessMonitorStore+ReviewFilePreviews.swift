import Foundation

/// Per-path preview fetch key used to dedupe background prewarm work.
public struct ReviewFilesPreviewFetchKey: Hashable, Sendable {
  public let pullRequestID: String
  public let headRefOid: String
  public let path: String
  public let lineLimit: UInt32

  public init(
    pullRequestID: String,
    headRefOid: String,
    path: String,
    lineLimit: UInt32
  ) {
    self.pullRequestID = pullRequestID
    self.headRefOid = headRefOid
    self.path = path
    self.lineLimit = lineLimit
  }
}

extension HarnessMonitorStore {
  /// Start aggressive background warming for first-line patch previews.
  public func startPatchPreviewPrewarm(
    forPullRequest pullRequestID: String,
    paths: [String],
    lineLimit: UInt32 = ReviewFilePreview.defaultLineLimit,
    largeDiffStrategy: FilesLargeDiffStrategy? = nil
  ) {
    let uniquePaths = dedupePaths(paths)
    guard !uniquePaths.isEmpty else { return }
    reviewFilesPreviewWarmTasks[pullRequestID]?.cancel()
    reviewFilesPreviewWarmTasks[pullRequestID] = Task { [weak self] in
      await self?.runPatchPreviewPrewarm(
        pullRequestID: pullRequestID,
        paths: uniquePaths,
        lineLimit: lineLimit,
        largeDiffStrategy: largeDiffStrategy
      )
    }
  }

  /// Fetch first-line previews for the supplied paths and store them on the
  /// per-PR view model. Paths already carrying a preview or full patch are
  /// skipped so expansion can stay an in-memory read once warmed.
  public func preparePatchPreviews(
    forPullRequest pullRequestID: String,
    paths: [String],
    lineLimit: UInt32 = ReviewFilePreview.defaultLineLimit,
    largeDiffStrategy: FilesLargeDiffStrategy? = nil
  ) async {
    let viewModel = self.viewModel(forPullRequest: pullRequestID)
    let pendingPaths = pendingPreviewPaths(
      paths: paths,
      viewModel: viewModel,
      lineLimit: lineLimit
    )
    guard !pendingPaths.isEmpty else { return }
    guard let client else {
      failPreviewPaths(pendingPaths, viewModel: viewModel, message: "Daemon client not available")
      return
    }
    for path in pendingPaths {
      viewModel.setPreviewState(path: path, state: .loading)
    }
    defer { clearPreviewPending(paths: pendingPaths, viewModel: viewModel, lineLimit: lineLimit) }

    let request = ReviewsFilesPreviewRequest(
      pullRequestID: pullRequestID,
      headRefOidExpected: viewModel.headRefOid,
      paths: pendingPaths,
      number: viewModel.number,
      repositoryFullName: viewModel.repositoryFullName,
      baseRefOidExpected: viewModel.baseRefOid,
      headRefName: viewModel.headRefName,
      baseRefName: viewModel.baseRefName,
      largeDiffStrategy: largeDiffStrategy,
      lineLimit: lineLimit
    )
    let interval = ReviewFilesPerf.beginPreviewFetch(
      pullRequestID: pullRequestID,
      pathCount: pendingPaths.count
    )
    defer { ReviewFilesPerf.end(interval) }
    do {
      let response = try await client.previewReviewFiles(request: request)
      if response.drifted {
        viewModel.previews.removeAll()
        viewModel.patches.removeAll()
        await refreshReviewFiles(pullRequestID: pullRequestID)
        return
      }
      ingestPreviewResponse(response, pendingPaths: pendingPaths, viewModel: viewModel)
    } catch {
      failPreviewPaths(pendingPaths, viewModel: viewModel, message: error.localizedDescription)
    }
  }

  private func runPatchPreviewPrewarm(
    pullRequestID: String,
    paths: [String],
    lineLimit: UInt32,
    largeDiffStrategy: FilesLargeDiffStrategy?
  ) async {
    let interval = ReviewFilesPerf.beginPreviewPrewarm(
      pullRequestID: pullRequestID,
      pathCount: paths.count
    )
    defer {
      ReviewFilesPerf.end(interval)
      reviewFilesPreviewWarmTasks.removeValue(forKey: pullRequestID)
    }
    for batch in paths.chunked(into: 24) {
      guard !Task.isCancelled else { return }
      await preparePatchPreviews(
        forPullRequest: pullRequestID,
        paths: batch,
        lineLimit: lineLimit,
        largeDiffStrategy: largeDiffStrategy
      )
    }
  }

  private func pendingPreviewPaths(
    paths: [String],
    viewModel: ReviewFilesViewModel,
    lineLimit: UInt32
  ) -> [String] {
    dedupePaths(paths).filter { path in
      if isPatchLoaded(path: path, viewModel: viewModel) { return false }
      if isPreviewLoadedOrLoading(path: path, viewModel: viewModel) { return false }
      let key = ReviewFilesPreviewFetchKey(
        pullRequestID: viewModel.pullRequestID,
        headRefOid: viewModel.headRefOid,
        path: path,
        lineLimit: lineLimit
      )
      return reviewFilesPreviewPendingFetches.insert(key).inserted
    }
  }

  private func clearPreviewPending(
    paths: [String],
    viewModel: ReviewFilesViewModel,
    lineLimit: UInt32
  ) {
    for path in paths {
      reviewFilesPreviewPendingFetches.remove(
        ReviewFilesPreviewFetchKey(
          pullRequestID: viewModel.pullRequestID,
          headRefOid: viewModel.headRefOid,
          path: path,
          lineLimit: lineLimit
        )
      )
    }
  }

  private func ingestPreviewResponse(
    _ response: ReviewsFilesPreviewResponse,
    pendingPaths: [String],
    viewModel: ReviewFilesViewModel
  ) {
    let returnedPaths = Set(response.previews.map(\.path))
    for path in pendingPaths where !returnedPaths.contains(path) {
      viewModel.setPreviewState(
        path: path,
        state: .failed("Daemon did not return a preview for this path")
      )
    }
    viewModel.ingest(previews: response.previews)
  }

  private func failPreviewPaths(
    _ paths: [String],
    viewModel: ReviewFilesViewModel,
    message: String
  ) {
    for path in paths {
      viewModel.setPreviewState(path: path, state: .failed(message))
    }
  }

  private func isPatchLoaded(path: String, viewModel: ReviewFilesViewModel) -> Bool {
    if case .loaded = viewModel.patches[path] ?? .notLoaded {
      return true
    }
    return false
  }

  private func isPreviewLoadedOrLoading(path: String, viewModel: ReviewFilesViewModel) -> Bool {
    switch viewModel.previews[path] ?? .notLoaded {
    case .loaded, .loading:
      return true
    case .notLoaded, .failed:
      return false
    }
  }

  private func dedupePaths(_ paths: [String]) -> [String] {
    var seen: Set<String> = []
    var out: [String] = []
    for path in paths where seen.insert(path).inserted {
      out.append(path)
    }
    return out
  }
}

extension Array {
  fileprivate func chunked(into size: Int) -> [[Element]] {
    guard size > 0 else { return [self] }
    return stride(from: 0, to: count, by: size).map {
      Array(self[$0..<Swift.min($0 + size, count)])
    }
  }
}
