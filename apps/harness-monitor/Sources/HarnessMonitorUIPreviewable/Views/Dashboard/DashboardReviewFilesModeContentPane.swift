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

  var body: some View {
    let timeline = store.reviewTimelineViewModel(for: item.pullRequestID)
    let threadIndex = threadIndexCache.index(for: timeline)
    let summary = DashboardReviewFilesSummary.make(
      files: viewModel.files,
      viewedByPath: viewModel.viewedByPath,
      threadIndex: threadIndex
    )
    let files = visibleFiles(threadIndex: threadIndex)

    VStack(alignment: .leading, spacing: 12) {
      header(summary: summary)
      searchField
      quickFilters
      fileList(files: files, threadIndex: threadIndex)
    }
    .padding(14)
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

  private var loadKey: String {
    [
      item.pullRequestID,
      store.connectionState == .online ? "online" : "offline",
    ].joined(separator: ":")
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
      Text("#\(item.number) \(item.title)")
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
    files: [ReviewFile],
    threadIndex: DashboardReviewFileThreadIndex
  ) -> some View {
    List(selection: selectedPathBinding) {
      ForEach(grouped(files: files), id: \.folder) { group in
        Section {
          ForEach(group.files) { file in
            DashboardReviewFilesNavigatorRow(
              file: file,
              viewedState: viewModel.viewedByPath[file.path] ?? file.viewerViewedState,
              threads: threadIndex.anchors(forPath: file.path)
            )
            .tag(file.path)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
          }
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

  private func visibleFiles(threadIndex: DashboardReviewFileThreadIndex) -> [ReviewFile] {
    var files: [ReviewFile] = []
    files.reserveCapacity(viewModel.filteredFiles.count)
    for file in viewModel.filteredFiles {
      if onlyUnviewed, (viewModel.viewedByPath[file.path] ?? file.viewerViewedState) == .viewed {
        continue
      }
      if onlyUnresolved, !threadIndex.hasUnresolvedAnchors(forPath: file.path) {
        continue
      }
      if let bucketFilter, !DashboardReviewFileClassifier.matches(file, bucket: bucketFilter) {
        continue
      }
      files.append(file)
    }
    return files
  }

  private func grouped(files: [ReviewFile]) -> [(folder: String, files: [ReviewFile])] {
    let rootLabel = "Repository root"
    let groups = Dictionary(grouping: files) { file in
      parentDirectory(for: file.path) ?? rootLabel
    }
    let sortedKeys = groups.keys.sorted { lhs, rhs in
      if lhs == rootLabel { return true }
      if rhs == rootLabel { return false }
      return lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
    return sortedKeys.map { key in
      (folder: key, files: groups[key] ?? [])
    }
  }

  private func parentDirectory(for path: String) -> String? {
    guard let slashIndex = path.lastIndex(of: "/") else { return nil }
    return String(path[..<slashIndex])
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
    let files = visibleFiles(threadIndex: threadIndex)
    restoreSelection(from: files)
    startPrewarm(files: files, selected: viewModel.selectedPath)
  }

  private func refreshSelectionAndPrewarmFromCurrentModel() {
    refreshSelectionAndPrewarm(
      threadIndex: currentThreadIndex()
    )
  }

  private func prewarmFromCurrentModel(selected: String? = nil) {
    let files = currentFiles()
    startPrewarm(files: files, selected: selected ?? viewModel.selectedPath)
  }

  private func currentFiles() -> [ReviewFile] {
    visibleFiles(threadIndex: currentThreadIndex())
  }

  private func currentThreadIndex() -> DashboardReviewFileThreadIndex {
    let timeline = store.reviewTimelineViewModel(for: item.pullRequestID)
    return threadIndexCache.index(for: timeline)
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
  let threads: [DashboardReviewFileThreadAnchor]

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
      if threads.contains(where: { !$0.isResolved }) {
        Image(systemName: "text.bubble.fill").foregroundStyle(.orange)
      }
      Text("+\(file.additions) -\(file.deletions)")
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

  private var fileName: String {
    file.path.split(separator: "/").last.map(String.init) ?? file.path
  }
}
