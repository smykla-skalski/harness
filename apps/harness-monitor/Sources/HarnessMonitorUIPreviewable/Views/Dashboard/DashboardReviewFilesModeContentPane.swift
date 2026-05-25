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
  @State private var filter = DashboardReviewFilesFilterState()
  @State private var onlyUnresolved = false
  @State private var onlyUnviewed = false
  @State private var bucketFilter: DashboardReviewFileBucket?
  @State private var threadIndexCache = DashboardReviewFileThreadIndexCache()
  @State private var presentationCache = DashboardReviewFilesModePresentationCache()

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
      fileList(presentation: presentation)
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

  private func fileList(presentation: DashboardReviewFilesModePresentation) -> some View {
    List(selection: selectedPathBinding) {
      ForEach(presentation.groups) { group in
        Section {
          ForEach(group.rows) { row in
            DashboardReviewFilesNavigatorRow(
              file: row.file,
              viewedState: row.viewedState,
              threads: row.threads
            )
            .tag(row.file.path)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
          }
        } header: {
          Text(group.folder)
        }
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
  }

  private var selectedPathBinding: Binding<String?> {
    Binding(
      get: { viewModel.selectedPath },
      set: { onSelectPath($0) }
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
  }

  private func loadFilesAndTimeline() async {
    guard store.connectionState == .online else { return }
    await store.prepareReviewFiles(pullRequestID: item.pullRequestID)
    await store.prepareReviewTimeline(for: item)
    prewarmFromCurrentModel()
  }

  private func restoreSelection(from files: [ReviewFile]) {
    if let selected = viewModel.selectedPath, files.contains(where: { $0.path == selected }) {
      return
    }
    onSelectPath(files.first?.path ?? viewModel.filteredFiles.first?.path)
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
    fileName = Self.fileName(for: file.path)
    hasUnresolvedThreads = threads.contains(where: { !$0.isResolved })
    changeCountLabel = "+\(file.additions) -\(file.deletions)"
  }

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: file.isBinary ? "photo" : "doc.text")
        .foregroundStyle(.secondary)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 2) {
        Text(fileName)
          .font(.body.weight(.semibold))
          .lineLimit(1)
          .truncationMode(.middle)
        Text(file.path)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
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

  private static func fileName(for path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? path
  }
}
