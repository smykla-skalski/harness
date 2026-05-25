import HarnessMonitorKit
import SwiftUI

/// Inline PR file-changes section inside the Dashboard Reviews
/// detail pane. Resolves the per-PR view model from the store; the
/// detail view passes only the pullRequestID so changes to one PR's
/// files don't invalidate other detail panes mounted in tab groups.
struct DashboardReviewFilesSection: View {
  private static let fileBatchSize = 24
  private static let backgroundPreviewPrewarmLimit = fileBatchSize * 3

  let pullRequestID: String
  let repositoryID: String
  let onHideFilesForPR: () -> Void

  @Environment(HarnessMonitorStore.self)
  private var store
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.reviewsPreferences)
  private var preferences
  @State private var filter = DashboardReviewFilesFilterState()
  /// Latest local-clone progress event for this PR's repository. Set
  /// from a per-repo `observeLocalCloneProgress` subscription started
  /// once we know the `repositoryFullName`. Cleared on
  /// `.completed`/`.failed` so the chip disappears.
  @State private var cloningProgress: ReviewLocalCloneProgress?
  @State private var visibleFileLimit = Self.fileBatchSize
  @State private var threadIndexCache = DashboardReviewFileThreadIndexCache()

  init(
    pullRequestID: String,
    repositoryID: String = "",
    onHideFilesForPR: @escaping () -> Void = {}
  ) {
    self.pullRequestID = pullRequestID
    self.repositoryID = repositoryID
    self.onHideFilesForPR = onHideFilesForPR
  }

  var body: some View {
    let viewModel = store.viewModel(forPullRequest: pullRequestID)
    let threadIndex = threadIndexCache.index(
      for: store.reviewTimelineViewModel(for: pullRequestID)
    )
    let isDaemonOnline = store.connectionState == .online && store.apiClient != nil
    return VStack(alignment: .leading, spacing: 12) {
      DashboardReviewFilesHeader(
        viewModel: viewModel,
        filter: filter,
        fontScale: fontScale,
        viewMode: viewModeBinding(viewModel: viewModel)
      )
      contentBody(
        viewModel: viewModel,
        threadIndex: threadIndex,
        isDaemonOnline: isDaemonOnline
      )
    }
    .task(
      id: ReviewFilesTaskKey(
        pullRequestID: pullRequestID,
        isDaemonOnline: isDaemonOnline
      )
    ) {
      guard isDaemonOnline else { return }
      await store.prepareReviewFiles(pullRequestID: pullRequestID)
      startPreviewPrewarm(viewModel: viewModel)
    }
    .task(id: viewModel.repositoryFullName ?? "") {
      await subscribeToCloneProgress(repoFullName: viewModel.repositoryFullName)
    }
    .onAppear { syncFilterFromPreferences(viewModel: viewModel) }
    .onChange(of: preferences.snapshot.filesDefaultViewModeRaw) { _, _ in
      syncViewModeFromPreferences(viewModel: viewModel)
    }
    .onChange(of: preferences.snapshot.filesHideGenerated) { _, _ in
      syncFilterFromPreferences(viewModel: viewModel)
    }
    .onChange(of: preferences.snapshot.filesHideWhitespaceOnly) { _, _ in
      syncFilterFromPreferences(viewModel: viewModel)
    }
    .onChange(of: preferences.compiledGeneratedPatternMatcher) { _, _ in
      syncFilterFromPreferences(viewModel: viewModel)
    }
    .onChange(of: filter.snapshotID) { _, _ in
      viewModel.applyFilter(filter.snapshot)
      resetVisibleFiles()
      startPreviewPrewarm(viewModel: viewModel)
    }
    .onChange(of: filter.hideGenerated) { _, newValue in
      preferences.update { $0.filesHideGenerated = newValue }
    }
    .onChange(of: filter.hideWhitespaceOnly) { _, newValue in
      preferences.update { $0.filesHideWhitespaceOnly = newValue }
    }
    .onChange(of: viewModel.sortMode) { _, newMode in
      preferences.update { $0.filesSortModeRaw = newMode.rawValue }
      startPreviewPrewarm(viewModel: viewModel)
    }
    .onChange(of: pullRequestID) { _, _ in
      syncFilterFromPreferences(viewModel: viewModel)
      resetVisibleFiles()
    }
    .onChange(of: visibleFileLimit) { _, _ in
      startPreviewPrewarm(viewModel: viewModel)
    }
    .accessibilityIdentifier("dashboardReviewFilesSection")
  }

  @ViewBuilder
  private func contentBody(
    viewModel: ReviewFilesViewModel,
    threadIndex: DashboardReviewFileThreadIndex,
    isDaemonOnline: Bool
  ) -> some View {
    switch viewModel.state {
    case .idle, .loading:
      if !isDaemonOnline {
        DashboardReviewFilesEmptyState(reason: .waitingForDaemon, fontScale: fontScale)
      } else if let cloning = activeCloningProgress {
        DashboardReviewFilesEmptyState(
          reason: .cloning(progress: cloning),
          fontScale: fontScale,
          onHideFilesForPR: onHideFilesForPR
        )
      } else {
        DashboardReviewFilesEmptyState(reason: .loading, fontScale: fontScale)
      }
    case .error(let message):
      if !isDaemonOnline {
        DashboardReviewFilesEmptyState(reason: .waitingForDaemon, fontScale: fontScale)
      } else {
        DashboardReviewFilesEmptyState(
          reason: .error(message: message),
          fontScale: fontScale
        )
      }
    case .loaded:
      if viewModel.filteredFiles.isEmpty {
        DashboardReviewFilesEmptyState(
          reason: viewModel.files.isEmpty ? .noFiles : .filteredOut,
          fontScale: fontScale
        )
      } else {
        filesList(viewModel: viewModel, threadIndex: threadIndex)
      }
    }
  }

  /// Returns the active progress event only when it's a `.started`
  /// event (so we don't keep the chip around once the runtime reports
  /// .completed / .failed and the empty-state transitions to its
  /// real loaded/empty state).
  private var activeCloningProgress: ReviewLocalCloneProgress? {
    guard let progress = cloningProgress, progress.kind == .started else { return nil }
    return progress
  }

  private func subscribeToCloneProgress(repoFullName: String?) async {
    guard let repoFullName, !repoFullName.isEmpty else {
      cloningProgress = nil
      return
    }
    for await event in store.observeLocalCloneProgress(repoFullName: repoFullName) {
      switch event.kind {
      case .started:
        cloningProgress = event
      case .completed, .failed:
        cloningProgress = nil
      }
    }
  }

  private func filesList(
    viewModel: ReviewFilesViewModel,
    threadIndex: DashboardReviewFileThreadIndex
  ) -> some View {
    LazyVStack(alignment: .leading, spacing: 8) {
      ForEach(viewModel.filteredFiles.prefix(visibleFileLimit), id: \.path) { file in
        DashboardReviewFileCard(
          file: file,
          viewedState: viewModel.viewedByPath[file.path] ?? file.viewerViewedState,
          previewState: viewModel.previews[file.path] ?? .notLoaded,
          patchState: viewModel.patches[file.path] ?? .notLoaded,
          viewMode: preferences.snapshot.filesDefaultViewMode,
          pullRequestID: pullRequestID,
          repositoryID: repositoryID,
          repositoryFullName: viewModel.repositoryFullName,
          headRefOid: viewModel.headRefOid,
          fontScale: fontScale,
          threads: threadIndex.anchors(forPath: file.path),
          onToggleViewed: { newValue in
            store.setFileViewed(
              pullRequestID: pullRequestID,
              path: file.path,
              viewed: newValue
            )
          },
          onLoadPreview: { [strategy = preferences.snapshot.filesLargeDiffStrategy] in
            Task {
              await store.preparePatchPreviews(
                forPullRequest: pullRequestID,
                paths: [file.path],
                largeDiffStrategy: strategy
              )
            }
          },
          onLoadPatch: { [strategy = preferences.snapshot.filesLargeDiffStrategy] in
            Task {
              await store.preparePatches(
                forPullRequest: pullRequestID,
                paths: [file.path],
                largeDiffStrategy: strategy
              )
            }
          }
        )
        .environment(
          \.reviewInlineConversationContext,
          conversationContext(
            file: file,
            threads: threadIndex.threads(forPath: file.path),
            repository: viewModel.repositoryFullName
          )
        )
      }
      showMoreFilesButton(totalCount: viewModel.filteredFiles.count)
    }
  }

  private func conversationContext(
    file: ReviewFile,
    threads: [DashboardReviewFileThread],
    repository: String?
  ) -> DashboardReviewInlineConversationContext {
    DashboardReviewInlineConversationContext(
      threads: threads,
      visibility: preferences.snapshot.filesConversationVisibility,
      viewerLogin: nil,
      loadAvatar: { login, avatarURL, targetPixel in
        await store.reviewAvatarImage(
          login: login,
          avatarURL: avatarURL,
          targetPixel: targetPixel
        )
      },
      onResolveToggle: { threadID, desired in
        _ = await store.setReviewThreadResolved(
          threadID: threadID,
          pullRequestID: pullRequestID,
          desired: desired
        )
      },
      onReply: { threadID, body in
        guard let thread = threads.first(where: { $0.id == threadID }) else { return false }
        return await store.postReviewFileComment(
          pullRequestID: pullRequestID,
          repository: repository,
          draft: .reply(file: file, thread: thread.anchor),
          body: body,
          viewerLogin: nil
        )
      }
    )
  }

  @ViewBuilder
  private func showMoreFilesButton(totalCount: Int) -> some View {
    let hiddenCount = max(totalCount - visibleFileLimit, 0)
    if hiddenCount > 0 {
      Button("Show \(min(Self.fileBatchSize, hiddenCount)) more files") {
        visibleFileLimit += Self.fileBatchSize
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
      .help("Render the next batch of changed files")
      .accessibilityLabel("Show more changed files")
    }
  }

  private func syncFilterFromPreferences(viewModel: ReviewFilesViewModel) {
    let prefs = preferences.snapshot
    filter.hideGenerated = prefs.filesHideGenerated
    filter.hideWhitespaceOnly = prefs.filesHideWhitespaceOnly
    filter.generatedPathMatcher = preferences.compiledGeneratedPatternMatcher
    if viewModel.sortMode != prefs.filesSortMode {
      viewModel.applySort(prefs.filesSortMode)
    }
    viewModel.defaultViewMode = prefs.filesDefaultViewMode
  }

  private func syncViewModeFromPreferences(viewModel: ReviewFilesViewModel) {
    viewModel.defaultViewMode = preferences.snapshot.filesDefaultViewMode
  }

  private func viewModeBinding(viewModel: ReviewFilesViewModel) -> Binding<FilesViewMode> {
    Binding(
      get: { preferences.snapshot.filesDefaultViewMode },
      set: { mode in
        viewModel.defaultViewMode = mode
        preferences.update { $0.filesDefaultViewModeRaw = mode.rawValue }
      }
    )
  }

  private func resetVisibleFiles() {
    visibleFileLimit = Self.fileBatchSize
  }

  private func startPreviewPrewarm(viewModel: ReviewFilesViewModel) {
    guard store.connectionState == .online, store.apiClient != nil else {
      store.startPatchPreviewPrewarm(
        forPullRequest: pullRequestID,
        visiblePaths: [],
        backgroundPaths: []
      )
      return
    }
    let paths = Self.prewarmPaths(
      files: viewModel.filteredFiles,
      visibleFileLimit: visibleFileLimit,
      backgroundLimit: Self.backgroundPreviewPrewarmLimit
    )
    store.startPatchPreviewPrewarm(
      forPullRequest: pullRequestID,
      visiblePaths: paths.visible,
      backgroundPaths: paths.background,
      largeDiffStrategy: preferences.snapshot.filesLargeDiffStrategy
    )
  }

  private static func prewarmPaths(
    files: [ReviewFile],
    visibleFileLimit: Int,
    backgroundLimit: Int
  ) -> (visible: [String], background: [String]) {
    let visibleLimit = max(visibleFileLimit, 0)
    let backgroundLimit = max(backgroundLimit, 0)
    var visible: [String] = []
    var background: [String] = []
    visible.reserveCapacity(min(visibleLimit, files.count))
    background.reserveCapacity(min(backgroundLimit, max(files.count - visibleLimit, 0)))

    var index = 0
    for file in files {
      defer { index += 1 }
      guard !file.isBinary else { continue }
      if index < visibleLimit {
        visible.append(file.path)
      } else if background.count < backgroundLimit {
        background.append(file.path)
        if background.count == backgroundLimit {
          break
        }
      }
    }
    return (visible: visible, background: background)
  }
}
