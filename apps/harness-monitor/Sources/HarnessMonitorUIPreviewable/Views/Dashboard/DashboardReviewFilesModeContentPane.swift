import HarnessMonitorKit
import SwiftUI

struct DashboardReviewFilesModeContentPane: View {
  private static let visiblePreviewPrewarmLimit = 16
  private static let backgroundPreviewPrewarmLimit = 48

  let item: ReviewItem
  let viewModel: ReviewFilesViewModel
  let store: HarnessMonitorStore
  let onBack: () -> Void
  let onSelectPath: (String?) -> Void

  @Environment(\.reviewsPreferences)
  private var preferences
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.openURL)
  private var openURL
  @State private var filter = DashboardReviewFilesFilterState()
  @State private var onlyUnresolved = false
  @State private var onlyUnviewed = false
  @State private var bucketFilter: DashboardReviewFileBucket?
  @State private var threadIndexCache = DashboardReviewFileThreadIndexCache()
  @State private var presentationCache = DashboardReviewFilesModePresentationCache()
  @State private var listSelection = DashboardReviewFilesListSelectionState()

  var body: some View {
    let timeline = store.reviewTimelineViewModel(for: item.pullRequestID)
    let threadIndex = threadIndexCache.index(for: timeline)
    let presentation = filesPresentation(
      threadIndex: threadIndex,
      timelineRevision: timeline.revision
    )

    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 12) {
        header(summary: presentation.summary)
        searchField
        quickFilters
      }
      .padding(.horizontal, 14)
      .padding(.top, 14)
      fileList(presentation: presentation, viewModel: viewModel)
    }
    .task(id: loadKey) {
      await loadFilesAndTimeline()
      restoreSelectionFromCurrentModel()
    }
    .onAppear {
      syncFilterFromPreferences()
      restoreSelectionFromCurrentModel()
    }
    .onChange(of: filter.snapshotID) { _, _ in
      viewModel.applyFilter(filter.snapshot)
      refreshSelectionAndPrewarmFromCurrentModel()
    }
    .onChange(of: filter.hideGenerated) { _, newValue in
      preferences.update { $0.filesHideGenerated = newValue }
    }
    .onChange(of: preferences.snapshot.filesHideGenerated) { _, _ in
      syncFilterFromPreferences()
    }
    .onChange(of: preferences.snapshot.filesHideWhitespaceOnly) { _, _ in
      syncFilterFromPreferences()
    }
    .onChange(of: preferences.compiledGeneratedPatternMatcher) { _, _ in
      syncFilterFromPreferences()
    }
    .onChange(of: viewModel.sortMode) { _, newMode in
      preferences.update { $0.filesSortModeRaw = newMode.rawValue }
      prewarmFromCurrentModel()
    }
    .onChange(of: viewModel.selectedPath) { _, path in
      let resolvedPath = syncListSelectionForPrimaryChange(
        path,
        visiblePaths: presentation.visibleFiles.map(\.path)
      )
      if resolvedPath != path {
        onSelectPath(resolvedPath)
        return
      }
      onSelectPath(path)
      if let selected = path {
        prewarmFromCurrentModel(selected: selected)
      }
    }
    .onChange(of: onlyUnresolved) { _, _ in
      refreshSelectionAndPrewarmFromCurrentModel()
    }
    .onChange(of: onlyUnviewed) { _, _ in
      refreshSelectionAndPrewarmFromCurrentModel()
    }
    .onChange(of: bucketFilter) { _, _ in
      refreshSelectionAndPrewarmFromCurrentModel()
    }
    .accessibilityIdentifier("dashboardReviewFilesModeContentPane")
  }

  private var loadKey: ReviewTimelineTaskKey {
    ReviewTimelineTaskKey(
      item: item,
      isDaemonOnline: store.connectionState == .online
    )
  }

  private func header(summary: DashboardReviewFilesSummary) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Button(action: onBack) {
          Label("Reviews", systemImage: "chevron.left")
        }
        .controlSize(.small)
        .help("Back to pull request list")
        Spacer(minLength: 8)
        Button {
          viewModel.selectNextUnviewed()
        } label: {
          Image(systemName: "arrow.down.to.line.compact")
        }
        .harnessPlainButtonStyle()
        .help("Next unviewed file")
        .accessibilityLabel("Next unviewed file")
      }
      Text(verbatim: "\(item.title) #\(item.number)")
        .font(HarnessMonitorTextSize.scaledFont(.headline, by: fontScale))
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 6) {
        DashboardReviewFilesSummaryChip(
          systemImage: "doc.on.doc",
          title: "\(summary.total) files"
        )
        DashboardReviewFilesSummaryChip(
          systemImage: "circle",
          title: "\(summary.unviewed) unviewed"
        )
        if summary.unresolvedThreads > 0 {
          DashboardReviewFilesSummaryChip(
            systemImage: "text.bubble",
            title: "\(summary.unresolvedThreads) unresolved",
            tint: .orange
          )
        }
      }
    }
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField("Filter files", text: $filter.text)
        .textFieldStyle(.plain)
      if !filter.text.isEmpty {
        Button {
          filter.clearText()
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .harnessPlainButtonStyle()
        .accessibilityLabel("Clear file filter")
      }
    }
    .padding(8)
    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
  }

  private var quickFilters: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Toggle(isOn: $filter.hideGenerated) {
          Text("Hide generated files")
            .allowsTightening(true)
            .minimumScaleFactor(0.9)
            .lineLimit(1)
        }
        .help(
          "Hide files matching the generated-files patterns "
            + "(e.g. package-lock.json, yarn.lock, vendor/, dist/). "
            + "Configure patterns in Settings > Reviews > Files."
        )
        Toggle("Unresolved", isOn: $onlyUnresolved)
        Toggle("Unviewed", isOn: $onlyUnviewed)
      }
      .toggleStyle(.checkbox)
      .controlSize(.small)
      Menu {
        Button("All file types") { bucketFilter = nil }
        Divider()
        ForEach(DashboardReviewFileBucket.allCases, id: \.self) { bucket in
          Button(bucket.rawValue) { bucketFilter = bucket }
        }
      } label: {
        Label(bucketFilter?.rawValue ?? "All file types", systemImage: "line.3.horizontal.decrease")
      }
      .controlSize(.small)
    }
  }

  private func fileList(
    presentation: DashboardReviewFilesModePresentation,
    viewModel: ReviewFilesViewModel
  ) -> some View {
    let visiblePaths = presentation.visibleFiles.map(\.path)
    List(selection: selectedPathsBinding(viewModel: viewModel, visiblePaths: visiblePaths)) {
      ForEach(presentation.groups) { group in
        Section {
          ForEach(group.rows) { row in
            DashboardReviewFilesNavigatorRow(
              file: row.file,
              viewedState: row.viewedState,
              threads: row.threads
            )
            .tag(row.file.path)
            .simultaneousGesture(
              SpatialTapGesture().onEnded { _ in
                noteFocusedFile(row.file.path, viewModel: viewModel)
              },
              including: .gesture
            )
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
          }
        } header: {
          fileSectionHeader(for: group)
        }
      }
    }
    .contextMenu(forSelectionType: String.self) { selection in
      fileSelectionContextMenu(
        for: selection,
        presentation: presentation,
        viewModel: viewModel,
        visiblePaths: visiblePaths
      )
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
  }

  private func fileSectionHeader(
    for group: DashboardReviewFilesModeGroup
  ) -> some View {
    HStack(alignment: .center, spacing: 8) {
      Text(group.folder)
      Spacer(minLength: 8)
      Text(verbatim: "\(group.rows.count)")
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
  }

  private func selectedPathsBinding(
    viewModel: ReviewFilesViewModel,
    visiblePaths: [String]
  ) -> Binding<Set<String>> {
    Binding(
      get: {
        listSelection.displayedSelection(fallbackPrimaryPath: viewModel.selectedPath)
      },
      set: {
        applyListSelection(
          $0,
          viewModel: viewModel,
          visiblePaths: visiblePaths
        )
      }
    )
  }

  private func syncFilterFromPreferences() {
    let prefs = preferences.snapshot
    filter.hideGenerated = prefs.filesHideGenerated
    filter.hideWhitespaceOnly = prefs.filesHideWhitespaceOnly
    filter.generatedPathMatcher = preferences.compiledGeneratedPatternMatcher
    viewModel.applyFilter(filter.snapshot)
    if viewModel.sortMode != prefs.filesSortMode {
      viewModel.applySort(prefs.filesSortMode)
    }
    viewModel.defaultViewMode = prefs.filesDefaultViewMode
    syncListSelection(
      visiblePaths: currentFiles().map(\.path),
      primaryPath: viewModel.selectedPath
    )
  }

  private func loadFilesAndTimeline() async {
    guard store.connectionState == .online else { return }
    await store.prepareReviewFiles(pullRequestID: item.pullRequestID)
    await store.prepareReviewTimeline(for: item)
    prewarmFromCurrentModel()
  }

  private func restoreSelection(from files: [ReviewFile]) {
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

  private func restoreSelectionFromCurrentModel() {
    restoreSelection(from: currentFiles())
  }

  private func refreshSelectionAndPrewarm(threadIndex: DashboardReviewFileThreadIndex) {
    let timeline = store.reviewTimelineViewModel(for: item.pullRequestID)
    let files = filesPresentation(
      threadIndex: threadIndex,
      timelineRevision: timeline.revision
    ).visibleFiles
    restoreSelection(from: files)
    startPrewarm(files: files, selected: viewModel.selectedPath)
  }

  private func refreshSelectionAndPrewarmFromCurrentModel() {
    refreshSelectionAndPrewarm(
      threadIndex: currentThreadIndex()
    )
  }

  private func prewarmFromCurrentModel(selected: String? = nil) {
    let files = currentPresentation().visibleFiles
    startPrewarm(files: files, selected: selected ?? viewModel.selectedPath)
  }

  private func currentFiles() -> [ReviewFile] {
    currentPresentation().visibleFiles
  }

  private func currentThreadIndex() -> DashboardReviewFileThreadIndex {
    let timeline = store.reviewTimelineViewModel(for: item.pullRequestID)
    return threadIndexCache.index(for: timeline)
  }

  private func currentPresentation() -> DashboardReviewFilesModePresentation {
    let timeline = store.reviewTimelineViewModel(for: item.pullRequestID)
    let threadIndex = threadIndexCache.index(for: timeline)
    return filesPresentation(threadIndex: threadIndex, timelineRevision: timeline.revision)
  }

  private func filesPresentation(
    threadIndex: DashboardReviewFileThreadIndex,
    timelineRevision: UInt64
  ) -> DashboardReviewFilesModePresentation {
    presentationCache.presentation(
      files: viewModel.files,
      filteredFiles: viewModel.filteredFiles,
      viewedByPath: viewModel.viewedByPath,
      threadIndex: threadIndex,
      key: DashboardReviewFilesModePresentationKey(
        filesRevision: viewModel.filesRevision,
        filteredFilesRevision: viewModel.filteredFilesRevision,
        viewedStateRevision: viewModel.viewedStateRevision,
        timelineRevision: timelineRevision,
        onlyUnresolved: onlyUnresolved,
        onlyUnviewed: onlyUnviewed,
        bucketFilter: bucketFilter,
        generatedPathMatcher: filter.generatedPathMatcher
      )
    )
  }

  private func startPrewarm(files: [ReviewFile], selected: String?) {
    let paths = prewarmPaths(files: files, selected: selected)
    store.startPatchPreviewPrewarm(
      forPullRequest: item.pullRequestID,
      visiblePaths: paths.visible,
      backgroundPaths: paths.background,
      largeDiffStrategy: preferences.snapshot.filesLargeDiffStrategy
    )
  }

  private func prewarmPaths(
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

  private func noteFocusedFile(
    _ path: String,
    viewModel: ReviewFilesViewModel
  ) {
    listSelection.notePrimarySelection(path)
    guard viewModel.selectedPath != path else { return }
    onSelectPath(path)
  }

  private func applyListSelection(
    _ newSelection: Set<String>,
    viewModel: ReviewFilesViewModel,
    visiblePaths: [String]
  ) {
    let primaryPath = listSelection.applySelection(
      newSelection,
      fallbackPrimaryPath: viewModel.selectedPath,
      orderedVisiblePaths: visiblePaths
    )
    syncPrimarySelection(primaryPath, viewModel: viewModel)
    syncListSelection(visiblePaths: visiblePaths, primaryPath: viewModel.selectedPath)
  }

  private func syncPrimarySelection(
    _ primaryPath: String?,
    viewModel: ReviewFilesViewModel
  ) {
    guard viewModel.selectedPath != primaryPath else { return }
    onSelectPath(primaryPath)
  }

  private func syncListSelectionForPrimaryChange(
    _ primaryPath: String?,
    visiblePaths: [String]
  ) -> String? {
    let displayed = listSelection.displayedSelection(fallbackPrimaryPath: primaryPath)
    if let primaryPath, !displayed.contains(primaryPath) {
      listSelection.collapse(to: primaryPath)
    } else if primaryPath == nil, !displayed.isEmpty {
      listSelection.collapse(to: nil)
    }
    return listSelection.prune(
      visiblePaths: Set(visiblePaths),
      fallbackPrimaryPath: primaryPath,
      orderedVisiblePaths: visiblePaths
    )
  }

  private func syncListSelection(
    visiblePaths: [String],
    primaryPath: String?
  ) {
    let nextPrimary = listSelection.prune(
      visiblePaths: Set(visiblePaths),
      fallbackPrimaryPath: primaryPath,
      orderedVisiblePaths: visiblePaths
    )
    guard nextPrimary != primaryPath else { return }
    onSelectPath(nextPrimary)
  }

  @ViewBuilder
  private func fileSelectionContextMenu(
    for selection: Set<String>,
    presentation: DashboardReviewFilesModePresentation,
    viewModel: ReviewFilesViewModel,
    visiblePaths: [String]
  ) -> some View {
    let items = contextMenuItems(
      for: selection,
      presentation: presentation,
      viewModel: viewModel
    )
    let _: Task<Void, Never> = Task { @MainActor in
      _ = primeSelectionForContextMenu(
        paths: selection,
        visiblePaths: visiblePaths,
        viewModel: viewModel
      )
    }
    if !items.isEmpty {
      let blobURLs = items.compactMap(\.blobURL)
      let pullRequestFileURLs = items.compactMap(\.pullRequestFileURL)
      Button(dashboardReviewCopyFilenamesMenuTitle(itemCount: items.count)) {
        HarnessMonitorClipboard.copy(items.map(\.fileName).joined(separator: "\n"))
      }
      Button(dashboardReviewCopyPathsMenuTitle(itemCount: items.count)) {
        HarnessMonitorClipboard.copy(items.map(\.file.path).joined(separator: "\n"))
      }
      if !blobURLs.isEmpty || !pullRequestFileURLs.isEmpty {
        Divider()
      }
      if !blobURLs.isEmpty {
        Button(dashboardReviewCopyGitHubLinksMenuTitle(itemCount: blobURLs.count)) {
          HarnessMonitorClipboard.copy(blobURLs.map(\.absoluteString).joined(separator: "\n"))
        }
        Button(dashboardReviewOpenGitHubLinksMenuTitle(itemCount: blobURLs.count)) {
          openGitHubURLs(blobURLs)
        }
      }
      if !pullRequestFileURLs.isEmpty {
        Button(
          dashboardReviewCopyPullRequestFileLinksMenuTitle(itemCount: pullRequestFileURLs.count)
        ) {
          HarnessMonitorClipboard.copy(
            pullRequestFileURLs.map(\.absoluteString).joined(separator: "\n")
          )
        }
      }
    }
  }

  private func contextMenuItems(
    for selection: Set<String>,
    presentation: DashboardReviewFilesModePresentation,
    viewModel: ReviewFilesViewModel
  ) -> [DashboardReviewFilesContextMenuItem] {
    guard !selection.isEmpty else { return [] }
    var items: [DashboardReviewFilesContextMenuItem] = []
    items.reserveCapacity(selection.count)
    for file in presentation.visibleFiles where selection.contains(file.path) {
      items.append(
        DashboardReviewFilesContextMenuItem(
          file: file,
          blobURL: dashboardReviewFileBlobURL(
            repositoryFullName: viewModel.repositoryFullName,
            headRefOid: viewModel.headRefOid,
            path: file.path
          ),
          pullRequestFileURL: dashboardReviewPullRequestFileURL(
            repositoryFullName: viewModel.repositoryFullName,
            pullRequestNumber: viewModel.number ?? item.number,
            path: file.path
          )
        )
      )
    }
    return items
  }

  @discardableResult
  private func primeSelectionForContextMenu(
    paths: Set<String>,
    visiblePaths: [String],
    viewModel: ReviewFilesViewModel
  ) -> Bool {
    guard !paths.isEmpty else { return false }
    let displayed = listSelection.displayedSelection(fallbackPrimaryPath: viewModel.selectedPath)
    guard displayed != paths else { return false }
    let primaryPath = listSelection.applySelection(
      paths,
      fallbackPrimaryPath: viewModel.selectedPath,
      orderedVisiblePaths: visiblePaths
    )
    syncPrimarySelection(primaryPath, viewModel: viewModel)
    syncListSelection(visiblePaths: visiblePaths, primaryPath: viewModel.selectedPath)
    return true
  }

  private func openGitHubURLs(_ urls: [URL]) {
    for url in urls {
      openURL(url)
    }
  }
}

private struct DashboardReviewFilesContextMenuItem: Identifiable {
  let file: ReviewFile
  let blobURL: URL?
  let pullRequestFileURL: URL?

  var id: String { file.path }
  var fileName: String { dashboardReviewFileName(for: file.path) }
}

private struct DashboardReviewFilesListSelectionState: Equatable {
  var selectedPaths: Set<String> = []
  var anchorPath: String?

  func displayedSelection(fallbackPrimaryPath: String?) -> Set<String> {
    if selectedPaths.isEmpty {
      guard let fallbackPrimaryPath else { return [] }
      return [fallbackPrimaryPath]
    }
    return selectedPaths
  }

  @discardableResult
  mutating func applySelection(
    _ newSelection: Set<String>,
    fallbackPrimaryPath: String?,
    orderedVisiblePaths: [String]
  ) -> String? {
    let previous = displayedSelection(fallbackPrimaryPath: fallbackPrimaryPath)
    let effective: Set<String>
    if newSelection.isEmpty, let fallbackPrimaryPath {
      effective = [fallbackPrimaryPath]
    } else {
      effective = newSelection
    }

    selectedPaths = effective
    let added = effective.subtracting(previous)
    if effective.count <= 1 {
      anchorPath = effective.first
    } else if let anchorPath, effective.contains(anchorPath) {
      self.anchorPath = anchorPath
    } else if let addedPath = orderedVisiblePaths.first(where: added.contains) {
      anchorPath = addedPath
    } else {
      anchorPath = primarySelectionPath(
        fallbackPrimaryPath: fallbackPrimaryPath,
        orderedVisiblePaths: orderedVisiblePaths
      )
    }

    return primarySelectionPath(
      fallbackPrimaryPath: fallbackPrimaryPath,
      orderedVisiblePaths: orderedVisiblePaths
    )
  }

  mutating func notePrimarySelection(_ path: String) {
    anchorPath = path
  }

  mutating func collapse(to primaryPath: String?) {
    selectedPaths = primaryPath.map { [$0] } ?? []
    anchorPath = primaryPath
  }

  @discardableResult
  mutating func prune(
    visiblePaths: Set<String>,
    fallbackPrimaryPath: String?,
    orderedVisiblePaths: [String]
  ) -> String? {
    let pruned = displayedSelection(fallbackPrimaryPath: fallbackPrimaryPath)
      .intersection(visiblePaths)
    if pruned.isEmpty {
      if let fallbackPrimaryPath, visiblePaths.contains(fallbackPrimaryPath) {
        collapse(to: fallbackPrimaryPath)
      } else {
        collapse(to: orderedVisiblePaths.first(where: visiblePaths.contains))
      }
      return primarySelectionPath(
        fallbackPrimaryPath: fallbackPrimaryPath,
        orderedVisiblePaths: orderedVisiblePaths
      )
    }

    selectedPaths = pruned
    anchorPath = orderedPrimary(
      in: pruned,
      fallbackPrimaryPath: fallbackPrimaryPath,
      orderedVisiblePaths: orderedVisiblePaths
    )
    return primarySelectionPath(
      fallbackPrimaryPath: fallbackPrimaryPath,
      orderedVisiblePaths: orderedVisiblePaths
    )
  }

  private func primarySelectionPath(
    fallbackPrimaryPath: String?,
    orderedVisiblePaths: [String]
  ) -> String? {
    let displayed = displayedSelection(fallbackPrimaryPath: fallbackPrimaryPath)
    return orderedPrimary(
      in: displayed,
      fallbackPrimaryPath: fallbackPrimaryPath,
      orderedVisiblePaths: orderedVisiblePaths
    )
  }

  private func orderedPrimary(
    in selection: Set<String>,
    fallbackPrimaryPath: String?,
    orderedVisiblePaths: [String]
  ) -> String? {
    if let anchorPath, selection.contains(anchorPath) {
      return anchorPath
    }
    if let fallbackPrimaryPath, selection.contains(fallbackPrimaryPath) {
      return fallbackPrimaryPath
    }
    if let visiblePath = orderedVisiblePaths.first(where: selection.contains) {
      return visiblePath
    }
    return selection.sorted().first
  }
}

private struct DashboardReviewFilesNavigatorRow: View {
  let file: ReviewFile
  let viewedState: ReviewFileViewedState
  private let fileName: String
  private let hasUnresolvedThreads: Bool
  private let changeCountLabel: String

  init(
    file: ReviewFile,
    viewedState: ReviewFileViewedState,
    threads: [DashboardReviewFileThreadAnchor]
  ) {
    self.file = file
    self.viewedState = viewedState
    fileName = dashboardReviewFileName(for: file.path)
    hasUnresolvedThreads = threads.contains(where: { !$0.isResolved })
    changeCountLabel = "+\(file.additions) -\(file.deletions)"
  }

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: file.isBinary ? "photo" : "doc.text")
        .foregroundStyle(.secondary)
        .frame(width: 16)
      Text(fileName)
        .font(.body.weight(.semibold))
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 8)
      if hasUnresolvedThreads {
        Image(systemName: "text.bubble.fill").foregroundStyle(.orange)
      }
      Text(changeCountLabel)
        .font(.caption.monospacedDigit().weight(.semibold))
        .foregroundStyle(.secondary)
      Image(systemName: viewedState == .viewed ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(viewedState == .viewed ? .green : .secondary.opacity(0.45))
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 9)
    .frame(maxWidth: .infinity, alignment: .leading)
    .help(file.path)
  }
}
