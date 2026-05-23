import HarnessMonitorKit
import SwiftUI

/// Inline PR file-changes section inside the Dashboard Reviews
/// detail pane. Resolves the per-PR view model from the store; the
/// detail view passes only the pullRequestID so changes to one PR's
/// files don't invalidate other detail panes mounted in tab groups.
struct DashboardReviewFilesSection: View {
  private static let fileBatchSize = 24

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
    let isDaemonOnline = store.connectionState == .online && store.apiClient != nil
    return VStack(alignment: .leading, spacing: 12) {
      DashboardReviewFilesHeader(
        viewModel: viewModel,
        filter: filter,
        fontScale: fontScale
      )
      contentBody(viewModel: viewModel, isDaemonOnline: isDaemonOnline)
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
        filesList(viewModel: viewModel)
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

  private func filesList(viewModel: ReviewFilesViewModel) -> some View {
    LazyVStack(alignment: .leading, spacing: 8) {
      ForEach(Array(viewModel.filteredFiles.prefix(visibleFileLimit)), id: \.path) { file in
        DashboardReviewFileCard(
          file: file,
          viewedState: viewModel.viewedByPath[file.path] ?? file.viewerViewedState,
          previewState: viewModel.previews[file.path] ?? .notLoaded,
          patchState: viewModel.patches[file.path] ?? .notLoaded,
          viewMode: viewModel.viewMode(forPath: file.path),
          pullRequestID: pullRequestID,
          repositoryID: repositoryID,
          fontScale: fontScale,
          onToggleViewed: { newValue in
            store.setFileViewed(
              pullRequestID: pullRequestID,
              path: file.path,
              viewed: newValue
            )
          },
          onChangeViewMode: { mode in
            viewModel.setViewMode(mode, forPath: file.path)
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
      }
      showMoreFilesButton(totalCount: viewModel.filteredFiles.count)
    }
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
    let visiblePaths = viewModel.filteredFiles
      .prefix(visibleFileLimit)
      .filter { !$0.isBinary }
      .map(\.path)
    let visibleSet = Set(visiblePaths)
    let remainingPaths = viewModel.filteredFiles
      .dropFirst(visibleFileLimit)
      .filter { !$0.isBinary && !visibleSet.contains($0.path) }
      .map(\.path)
    store.startPatchPreviewPrewarm(
      forPullRequest: pullRequestID,
      visiblePaths: visiblePaths,
      backgroundPaths: remainingPaths,
      largeDiffStrategy: preferences.snapshot.filesLargeDiffStrategy
    )
  }
}

/// Empty / loading / error / cloning states for the Files section.
struct DashboardReviewFilesEmptyState: View {
  enum Reason: Equatable {
    case loading
    case noFiles
    case filteredOut
    case error(message: String)
    /// Daemon is in the middle of `git clone` / `git fetch` via the
    /// local-clone runtime. The chip surfaces while the operation is
    /// in flight so the user understands why "Loading files..." takes
    /// longer than usual.
    case cloning(progress: ReviewLocalCloneProgress)
    /// Cached Reviews detail can render before daemon bootstrap finishes.
    /// Keep the Files section recoverable instead of storing a one-shot
    /// unavailable-client error.
    case waitingForDaemon
  }

  let reason: Reason
  let fontScale: CGFloat
  let titleFont: Font
  let subtitleFont: Font
  let captionFont: Font
  /// Optional escape hatch surfaced only while the daemon is cloning.
  /// When provided, the cloning empty-state offers a "Hide Files for
  /// this PR" button that dismisses the section locally without
  /// stopping the background clone or toggling the global setting.
  let onHideFilesForPR: (() -> Void)?

  @State private var cloningStartedAt: Date?

  init(
    reason: Reason,
    fontScale: CGFloat,
    onHideFilesForPR: (() -> Void)? = nil
  ) {
    self.reason = reason
    self.fontScale = fontScale
    titleFont = HarnessMonitorTextSize.scaledFont(.headline, by: fontScale)
    subtitleFont = HarnessMonitorTextSize.scaledFont(.subheadline, by: fontScale)
    captionFont = HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
    self.onHideFilesForPR = onHideFilesForPR
  }

  var body: some View {
    VStack(alignment: .center, spacing: 6) {
      icon
      Text(title).font(titleFont)
      if let subtitle {
        Text(subtitle).font(subtitleFont).foregroundStyle(.secondary)
      }
      cloningEscapeHatch
    }
    .frame(maxWidth: .infinity, alignment: .center)
    .padding(.vertical, 20)
    .accessibilityIdentifier("dashboardReviewFilesEmptyState")
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text(title))
    .onAppear {
      if case .cloning = reason, cloningStartedAt == nil {
        cloningStartedAt = Date.now
      }
    }
    .onChange(of: cloningIdentity) { _, newIdentity in
      cloningStartedAt = newIdentity == nil ? nil : Date.now
    }
  }

  @ViewBuilder private var cloningEscapeHatch: some View {
    if case .cloning = reason {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        let startedAt = cloningStartedAt ?? context.date
        let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
        Text("Cloning for \(elapsed)s")
          .font(captionFont)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .accessibilityLabel("Cloning has been running for \(elapsed) seconds")
      }
      .padding(.top, 2)
      if let onHide = onHideFilesForPR {
        Button("Hide Files for this PR", action: onHide)
          .controlSize(.small)
          .help(
            "Hides the Files section for this pull request only. "
              + "The daemon keeps cloning in the background. "
              + "Re-enable globally in Settings > Reviews > Files."
          )
          .accessibilityIdentifier("dashboardReviewFilesHideForPRButton")
          .padding(.top, 4)
      }
    }
  }

  private var icon: some View {
    Group {
      switch reason {
      case .loading, .cloning:
        ProgressView()
      case .waitingForDaemon:
        Image(systemName: "antenna.radiowaves.left.and.right")
      case .noFiles:
        Image(systemName: "doc.text.magnifyingglass")
      case .filteredOut:
        Image(systemName: "line.3.horizontal.decrease.circle")
      case .error:
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.orange)
      }
    }
  }

  private var title: String {
    switch reason {
    case .loading: return "Loading files…"
    case .waitingForDaemon: return "Waiting for daemon connection"
    case .noFiles: return "No files changed in this pull request"
    case .filteredOut: return "All files are hidden by the current filter"
    case .error: return "Failed to load files"
    case .cloning(let progress):
      return "\(progress.operation.presentLabel) \(progress.repoFullName)…"
    }
  }

  private var subtitle: String? {
    switch reason {
    case .error(let message): return message
    case .waitingForDaemon:
      return "Files will load automatically when the daemon is available."
    case .cloning: return "Local clone in progress so we can show the diff offline."
    default: return nil
    }
  }

  /// Stable identity for the in-flight clone. `nil` when the reason
  /// isn't `.cloning`, otherwise the daemon-reported repo so that
  /// navigating between two cloning PRs (different repos) resets the
  /// elapsed-time counter instead of accumulating across PRs.
  private var cloningIdentity: String? {
    guard case .cloning(let progress) = reason else { return nil }
    return progress.repoFullName
  }
}
