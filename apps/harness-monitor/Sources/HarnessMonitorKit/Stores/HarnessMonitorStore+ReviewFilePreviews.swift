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

struct ReviewFilesPreviewWarmState {
  var tasks: [String: Task<Void, Never>] = [:]
  var generations: [String: UInt64] = [:]
}

private struct ReviewFilesPreviewPrewarmPlan: Sendable {
  let pullRequestID: String
  let generation: UInt64
  let visiblePaths: [String]
  let backgroundPaths: [String]
  let lineLimit: UInt32
  let largeDiffStrategy: FilesLargeDiffStrategy?
}

extension HarnessMonitorStore {
  /// Start aggressive background warming for first-line patch previews.
  public func startPatchPreviewPrewarm(
    forPullRequest pullRequestID: String,
    paths: [String],
    lineLimit: UInt32 = ReviewFilePreview.defaultLineLimit,
    largeDiffStrategy: FilesLargeDiffStrategy? = nil
  ) {
    startPatchPreviewPrewarm(
      forPullRequest: pullRequestID,
      visiblePaths: paths,
      backgroundPaths: [],
      lineLimit: lineLimit,
      largeDiffStrategy: largeDiffStrategy
    )
  }

  /// Start background warming with the currently rendered files first.
  /// Reissuing this method cancels the previous warmer for the PR, so
  /// filter/sort/visible-batch changes do not spend work on stale rows.
  public func startPatchPreviewPrewarm(
    forPullRequest pullRequestID: String,
    visiblePaths: [String],
    backgroundPaths: [String],
    lineLimit: UInt32 = ReviewFilePreview.defaultLineLimit,
    largeDiffStrategy: FilesLargeDiffStrategy? = nil
  ) {
    let visible = dedupePaths(visiblePaths)
    let visibleSet = Set(visible)
    let background = dedupePaths(backgroundPaths).filter { !visibleSet.contains($0) }
    if let existing = reviewFilesPreviewWarmState.tasks[pullRequestID] {
      let interval = ReviewFilesPerf.beginPrewarmCancel(pullRequestID: pullRequestID)
      existing.cancel()
      ReviewFilesPerf.end(interval)
    }
    guard !visible.isEmpty || !background.isEmpty else {
      reviewFilesPreviewWarmState.tasks.removeValue(forKey: pullRequestID)
      reviewFilesPreviewWarmState.generations.removeValue(forKey: pullRequestID)
      return
    }
    let generation = (reviewFilesPreviewWarmState.generations[pullRequestID] ?? 0) + 1
    reviewFilesPreviewWarmState.generations[pullRequestID] = generation
    let plan = ReviewFilesPreviewPrewarmPlan(
      pullRequestID: pullRequestID,
      generation: generation,
      visiblePaths: visible,
      backgroundPaths: background,
      lineLimit: lineLimit,
      largeDiffStrategy: largeDiffStrategy
    )
    reviewFilesPreviewWarmState.tasks[pullRequestID] = Task { [weak self] in
      await self?.runPatchPreviewPrewarm(plan)
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
    let candidatePaths = candidatePreviewPaths(
      paths: paths,
      viewModel: viewModel
    )
    let cacheMissPaths = await applyCachedPreviews(
      candidatePaths,
      viewModel: viewModel,
      lineLimit: lineLimit
    )
    guard !Task.isCancelled else { return }
    let pendingPaths = pendingPreviewPaths(
      paths: cacheMissPaths,
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
      await persistPreviewResponse(response, viewModel: viewModel)
      ingestPreviewResponse(response, pendingPaths: pendingPaths, viewModel: viewModel)
    } catch {
      failPreviewPaths(pendingPaths, viewModel: viewModel, message: error.localizedDescription)
    }
  }

  private func runPatchPreviewPrewarm(_ plan: ReviewFilesPreviewPrewarmPlan) async {
    let pathCount = plan.visiblePaths.count + plan.backgroundPaths.count
    let interval = ReviewFilesPerf.beginPreviewPrewarm(
      pullRequestID: plan.pullRequestID,
      pathCount: pathCount,
      visiblePathCount: plan.visiblePaths.count
    )
    defer {
      ReviewFilesPerf.end(interval)
      if reviewFilesPreviewWarmState.generations[plan.pullRequestID] == plan.generation {
        reviewFilesPreviewWarmState.tasks.removeValue(forKey: plan.pullRequestID)
        reviewFilesPreviewWarmState.generations.removeValue(forKey: plan.pullRequestID)
      }
    }
    await warmPreviewBatches(
      pullRequestID: plan.pullRequestID,
      paths: plan.visiblePaths,
      lineLimit: plan.lineLimit,
      largeDiffStrategy: plan.largeDiffStrategy
    )
    guard !Task.isCancelled else { return }
    await warmPreviewBatches(
      pullRequestID: plan.pullRequestID,
      paths: plan.backgroundPaths,
      lineLimit: plan.lineLimit,
      largeDiffStrategy: plan.largeDiffStrategy
    )
  }

  private func warmPreviewBatches(
    pullRequestID: String,
    paths: [String],
    lineLimit: UInt32,
    largeDiffStrategy: FilesLargeDiffStrategy?
  ) async {
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

  private func candidatePreviewPaths(
    paths: [String],
    viewModel: ReviewFilesViewModel
  ) -> [String] {
    dedupePaths(paths).filter { path in
      !isPatchLoaded(path: path, viewModel: viewModel)
        && !isPreviewLoadedOrLoading(path: path, viewModel: viewModel)
    }
  }

  private func applyCachedPreviews(
    _ paths: [String],
    viewModel: ReviewFilesViewModel,
    lineLimit: UInt32
  ) async -> [String] {
    guard !paths.isEmpty else { return [] }
    let interval = ReviewFilesPerf.beginPreviewCacheRead(
      pullRequestID: viewModel.pullRequestID,
      pathCount: paths.count
    )
    defer { ReviewFilesPerf.end(interval) }

    var misses: [String] = []
    for path in paths {
      if let preview = await reviewFilePreviewStore.read(
        pullRequestID: viewModel.pullRequestID,
        headRefOid: viewModel.headRefOid,
        path: path,
        lineLimit: lineLimit
      ) {
        viewModel.setPreviewState(path: path, state: .loaded(preview))
      } else {
        misses.append(path)
      }
    }
    return misses
  }

  private func pendingPreviewPaths(
    paths: [String],
    viewModel: ReviewFilesViewModel,
    lineLimit: UInt32
  ) -> [String] {
    candidatePreviewPaths(paths: paths, viewModel: viewModel).filter { path in
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
    viewModel.noteRateLimitSnapshot(response.rateLimitSnapshot)
    viewModel.ingest(previews: response.previews)
  }

  private func persistPreviewResponse(
    _ response: ReviewsFilesPreviewResponse,
    viewModel: ReviewFilesViewModel
  ) async {
    guard !response.previews.isEmpty else { return }
    let interval = ReviewFilesPerf.beginPreviewCacheStore(
      pullRequestID: viewModel.pullRequestID,
      pathCount: response.previews.count
    )
    defer { ReviewFilesPerf.end(interval) }
    for preview in response.previews {
      await reviewFilePreviewStore.store(
        pullRequestID: viewModel.pullRequestID,
        headRefOid: viewModel.headRefOid,
        preview: preview
      )
    }
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
