import HarnessMonitorKit
import SwiftUI

extension DashboardReviewFilesModeContentPane {
  var loadKey: ReviewTimelineTaskKey {
    ReviewTimelineTaskKey(
      item: item,
      isDaemonOnline: store.connectionState == .online
    )
  }

  func syncFilterFromPreferences() {
    let prefs = preferences.snapshot
    let nextFilter = currentFilterState
    nextFilter.hideGenerated = prefs.filesHideGenerated
    nextFilter.hideWhitespaceOnly = prefs.filesHideWhitespaceOnly
    nextFilter.generatedPathMatcher = preferences.compiledGeneratedPatternMatcher
    replaceFilterState(nextFilter)
    viewModel.applyFilter(nextFilter.snapshot)
    if viewModel.sortMode != prefs.filesSortMode {
      viewModel.applySort(prefs.filesSortMode)
    }
    viewModel.defaultViewMode = prefs.filesDefaultViewMode
    syncListSelection(
      visiblePaths: currentFiles().map(\.path),
      primaryPath: viewModel.selectedPath
    )
  }

  func loadFilesAndTimeline() async {
    guard store.connectionState == .online else { return }
    await store.prepareReviewFiles(pullRequestID: item.pullRequestID)
    await store.prepareReviewTimeline(for: item)
    prewarmFromCurrentModel()
  }

  func restoreSelection(from files: [ReviewFile]) {
    if let selected = viewModel.selectedPath, files.contains(where: { $0.path == selected }) {
      syncListSelection(
        visiblePaths: files.map(\.path),
        primaryPath: selected
      )
      return
    }
    onSelectPath(files.first?.path ?? viewModel.filteredFiles.first?.path)
    syncListSelection(
      visiblePaths: files.map(\.path),
      primaryPath: viewModel.selectedPath
    )
  }

  func restoreSelectionFromCurrentModel() {
    restoreSelection(from: currentFiles())
  }

  func refreshSelectionAndPrewarm(threadIndex: DashboardReviewFileThreadIndex) {
    let timeline = store.reviewTimelineViewModel(for: item.pullRequestID)
    let files = filesPresentation(
      threadIndex: threadIndex,
      timelineRevision: timeline.revision
    ).visibleFiles
    restoreSelection(from: files)
    startPrewarm(files: files, selected: viewModel.selectedPath)
  }

  func refreshSelectionAndPrewarmFromCurrentModel() {
    refreshSelectionAndPrewarm(
      threadIndex: currentThreadIndex()
    )
  }

  func prewarmFromCurrentModel(selected: String? = nil) {
    let files = currentPresentation().visibleFiles
    startPrewarm(files: files, selected: selected ?? viewModel.selectedPath)
  }

  func currentFiles() -> [ReviewFile] {
    currentPresentation().visibleFiles
  }

  func currentThreadIndex() -> DashboardReviewFileThreadIndex {
    let timeline = store.reviewTimelineViewModel(for: item.pullRequestID)
    return cachedThreadIndex(for: timeline)
  }

  func currentPresentation() -> DashboardReviewFilesModePresentation {
    let timeline = store.reviewTimelineViewModel(for: item.pullRequestID)
    let threadIndex = cachedThreadIndex(for: timeline)
    return filesPresentation(threadIndex: threadIndex, timelineRevision: timeline.revision)
  }

  func expandedFilePaths(
    in groups: [DashboardReviewFilesModeGroup],
    collapsedFolders: DashboardReviewFilesCollapsedFolders
  ) -> [String] {
    var paths: [String] = []
    for group in groups where !collapsedFolders.contains(group.folder) {
      paths.append(contentsOf: group.rows.map(\.file.path))
    }
    return paths
  }

  func toggleFolderCollapse(
    _ folder: String,
    collapsedFolders: DashboardReviewFilesCollapsedFolders
  ) {
    var next = collapsedFolders
    next.toggle(folder)
    collapsedFoldersStorage = next.encodedString
  }

  func startPrewarm(files: [ReviewFile], selected: String?) {
    let paths = prewarmPaths(files: files, selected: selected)
    store.startPatchPreviewPrewarm(
      forPullRequest: item.pullRequestID,
      visiblePaths: paths.visible,
      backgroundPaths: paths.background,
      largeDiffStrategy: preferences.snapshot.filesLargeDiffStrategy
    )
  }

  func prewarmPaths(
    files: [ReviewFile],
    selected: String?
  ) -> (visible: [String], background: [String]) {
    var visible: [String] = []
    var background: [String] = []
    var seen = Set<String>()
    visible.reserveCapacity(Self.visiblePreviewPrewarmLimit)
    background.reserveCapacity(Self.backgroundPreviewPrewarmLimit)

    func append(_ file: ReviewFile) {
      guard !file.isBinary, seen.insert(file.path).inserted else { return }
      if visible.count < Self.visiblePreviewPrewarmLimit {
        visible.append(file.path)
      } else if background.count < Self.backgroundPreviewPrewarmLimit {
        background.append(file.path)
      }
    }

    if let selected, let file = files.first(where: { $0.path == selected }) {
      append(file)
    }
    for file in files {
      append(file)
      if background.count == Self.backgroundPreviewPrewarmLimit {
        break
      }
    }
    return (visible: visible, background: background)
  }

  func noteFocusedFile(
    _ path: String,
    viewModel: ReviewFilesViewModel
  ) {
    noteStoredPrimarySelection(path)
    guard viewModel.selectedPath != path else { return }
    onSelectPath(path)
  }

  func applyListSelection(
    _ newSelection: Set<String>,
    viewModel: ReviewFilesViewModel,
    visiblePaths: [String]
  ) {
    let primaryPath = applyStoredListSelection(
      newSelection,
      fallbackPrimaryPath: viewModel.selectedPath,
      orderedVisiblePaths: visiblePaths
    )
    syncPrimarySelection(primaryPath, viewModel: viewModel)
    syncListSelection(visiblePaths: visiblePaths, primaryPath: viewModel.selectedPath)
  }

  func syncPrimarySelection(
    _ primaryPath: String?,
    viewModel: ReviewFilesViewModel
  ) {
    guard viewModel.selectedPath != primaryPath else { return }
    onSelectPath(primaryPath)
  }

  func syncListSelectionForPrimaryChange(
    _ primaryPath: String?,
    visiblePaths: [String]
  ) -> String? {
    let displayed = displayedStoredListSelection(fallbackPrimaryPath: primaryPath)
    if let primaryPath, !displayed.contains(primaryPath) {
      collapseStoredListSelection(to: primaryPath)
    } else if primaryPath == nil, !displayed.isEmpty {
      collapseStoredListSelection(to: nil)
    }
    return pruneStoredListSelection(
      visiblePaths: Set(visiblePaths),
      fallbackPrimaryPath: primaryPath,
      orderedVisiblePaths: visiblePaths
    )
  }

  func syncListSelection(
    visiblePaths: [String],
    primaryPath: String?
  ) {
    let nextPrimary = pruneStoredListSelection(
      visiblePaths: Set(visiblePaths),
      fallbackPrimaryPath: primaryPath,
      orderedVisiblePaths: visiblePaths
    )
    guard nextPrimary != primaryPath else { return }
    onSelectPath(nextPrimary)
  }
}
