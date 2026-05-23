import HarnessMonitorKit
import SwiftUI

struct DashboardReviewFilesModeContentPane: View {
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

  var body: some View {
    let timeline = store.reviewTimelineViewModel(for: item.pullRequestID)
    let threadIndex = DashboardReviewFileThreadIndex(entries: timeline.entries)
    let summary = DashboardReviewFilesSummary.make(
      files: viewModel.files,
      viewedByPath: viewModel.viewedByPath,
      threadIndex: threadIndex
    )
    let files = visibleFiles(threadIndex: threadIndex)

    VStack(alignment: .leading, spacing: 12) {
      header(summary: summary)
      searchAndLayout
      quickFilters
      fileList(files: files, threadIndex: threadIndex)
    }
    .padding(14)
    .task(id: loadKey) {
      await loadFilesAndTimeline()
      restoreSelection(from: files)
    }
    .onAppear {
      syncFilterFromPreferences()
      restoreSelection(from: files)
    }
    .onChange(of: filter.snapshotID) { _, _ in
      viewModel.applyFilter(filter.snapshot)
      restoreSelection(from: visibleFiles(threadIndex: threadIndex))
      startPrewarm(files: visibleFiles(threadIndex: threadIndex))
    }
    .onChange(of: viewModel.sortMode) { _, newMode in
      preferences.update { $0.filesSortModeRaw = newMode.rawValue }
      startPrewarm(files: files)
    }
    .onChange(of: viewModel.selectedPath) { _, path in
      onSelectPath(path)
      if let selected = path {
        startPrewarm(files: selectedFirst(files, selected: selected))
      }
    }
    .onChange(of: onlyUnresolved) { _, _ in restoreSelection(from: files) }
    .onChange(of: onlyUnviewed) { _, _ in restoreSelection(from: files) }
    .onChange(of: bucketFilter) { _, _ in restoreSelection(from: files) }
    .accessibilityIdentifier("dashboardReviewFilesModeContentPane")
  }

  private var loadKey: String {
    [
      item.pullRequestID,
      store.connectionState == .online ? "online" : "offline",
      preferences.snapshot.filesDefaultViewModeRaw,
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

  private var searchAndLayout: some View {
    VStack(alignment: .leading, spacing: 8) {
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

      Picker("Layout", selection: viewModeBinding) {
        ForEach(FilesViewMode.allCases, id: \.self) { mode in
          Text(mode == .unified ? "Unified" : "Split").tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .controlSize(.small)
    }
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
        Section(group.folder) {
          ForEach(group.files) { file in
            DashboardReviewFilesNavigatorRow(
              file: file,
              viewedState: viewModel.viewedByPath[file.path] ?? file.viewerViewedState,
              threads: threadIndex.anchors(forPath: file.path)
            )
            .tag(file.path)
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

  private var viewModeBinding: Binding<FilesViewMode> {
    Binding(
      get: { preferences.snapshot.filesDefaultViewMode },
      set: { mode in preferences.update { $0.filesDefaultViewModeRaw = mode.rawValue } }
    )
  }

  private func visibleFiles(threadIndex: DashboardReviewFileThreadIndex) -> [ReviewFile] {
    viewModel.filteredFiles.filter { file in
      if onlyUnviewed, (viewModel.viewedByPath[file.path] ?? file.viewerViewedState) == .viewed {
        return false
      }
      if onlyUnresolved, threadIndex.anchors(forPath: file.path).allSatisfy(\.isResolved) {
        return false
      }
      if let bucketFilter, !DashboardReviewFileClassifier.matches(file, bucket: bucketFilter) {
        return false
      }
      return true
    }
  }

  private func grouped(files: [ReviewFile]) -> [(folder: String, files: [ReviewFile])] {
    let groups = Dictionary(grouping: files) { file in
      file.path.split(separator: "/").first.map(String.init) ?? "Files"
    }
    return groups.keys.sorted().map { key in
      (folder: key, files: groups[key] ?? [])
    }
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
    startPrewarm(files: viewModel.filteredFiles)
  }

  private func restoreSelection(from files: [ReviewFile]) {
    if let selected = viewModel.selectedPath, files.contains(where: { $0.path == selected }) {
      return
    }
    onSelectPath(files.first?.path ?? viewModel.filteredFiles.first?.path)
  }

  private func startPrewarm(files: [ReviewFile]) {
    let selectedFirst = selectedFirst(files, selected: viewModel.selectedPath)
    let visible = selectedFirst.prefix(16).filter { !$0.isBinary }.map(\.path)
    let visibleSet = Set(visible)
    let background = selectedFirst.dropFirst(16).filter {
      !$0.isBinary && !visibleSet.contains($0.path)
    }.map(\.path)
    store.startPatchPreviewPrewarm(
      forPullRequest: item.pullRequestID,
      visiblePaths: visible,
      backgroundPaths: background,
      largeDiffStrategy: preferences.snapshot.filesLargeDiffStrategy
    )
  }

  private func selectedFirst(_ files: [ReviewFile], selected: String?) -> [ReviewFile] {
    guard let selected, let index = files.firstIndex(where: { $0.path == selected }) else {
      return files
    }
    var copy = files
    let file = copy.remove(at: index)
    copy.insert(file, at: 0)
    return copy
  }
}

private struct DashboardReviewFilesNavigatorRow: View {
  let file: ReviewFile
  let viewedState: ReviewFileViewedState
  let threads: [DashboardReviewFileThreadAnchor]

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: file.isBinary ? "photo" : "doc.text")
        .foregroundStyle(.secondary)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 2) {
        Text(file.path.split(separator: "/").last.map(String.init) ?? file.path)
          .lineLimit(1)
        Text(file.path)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 4)
      if threads.contains(where: { !$0.isResolved }) {
        Image(systemName: "text.bubble.fill").foregroundStyle(.orange)
      }
      Text("+\(file.additions) -\(file.deletions)")
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
      Image(systemName: viewedState == .viewed ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(viewedState == .viewed ? .green : .secondary.opacity(0.45))
    }
    .help(file.path)
  }
}
