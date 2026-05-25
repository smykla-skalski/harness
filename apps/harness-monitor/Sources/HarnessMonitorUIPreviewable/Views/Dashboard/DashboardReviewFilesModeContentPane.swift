import HarnessMonitorKit
import SwiftUI

struct DashboardReviewFilesModeContentPane: View {
  static let visiblePreviewPrewarmLimit = 16
  static let backgroundPreviewPrewarmLimit = 48

  let item: ReviewItem
  let viewModel: ReviewFilesViewModel
  let store: HarnessMonitorStore
  let onBack: () -> Void
  let onSelectPath: (String?) -> Void

  @Environment(\.reviewsPreferences)
  var preferences
  @Environment(\.fontScale)
  var fontScale
  @Environment(\.openURL)
  var openURL
  @SceneStorage("dashboard.reviews.files.collapsed-folders")
  var collapsedFoldersStorage = ""
  @State var filter = DashboardReviewFilesFilterState()
  @State var onlyUnresolved = false
  @State var onlyUnviewed = false
  @State var bucketFilter: DashboardReviewFileBucket?
  @State var threadIndexCache = DashboardReviewFileThreadIndexCache()
  @State private var presentationCache = DashboardReviewFilesModePresentationCache()
  @State var listSelection = DashboardReviewFilesListSelectionState()

  var body: some View {
    let timeline = store.reviewTimelineViewModel(for: item.pullRequestID)
    let threadIndex = threadIndexCache.index(for: timeline)
    let presentation = filesPresentation(
      threadIndex: threadIndex,
      timelineRevision: timeline.revision
    )
    let collapsedFolders = DashboardReviewFilesCollapsedFolders.decode(
      from: collapsedFoldersStorage
    )

    return VStack(alignment: .leading, spacing: 14) {
      topControlsPane(summary: presentation.summary)
      fileList(
        presentation: presentation,
        viewModel: viewModel,
        collapsedFolders: collapsedFolders
      )
    }
    .padding(0)
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
        visiblePaths: expandedFilePaths(
          in: presentation.groups,
          collapsedFolders: collapsedFolders
        )
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

  var loadKey: ReviewTimelineTaskKey {
    ReviewTimelineTaskKey(
      item: item,
      isDaemonOnline: store.connectionState == .online
    )
  }

  /// Resolves the cached file presentation. Kept on the main type (not the
  /// +Load companion) so `presentationCache` can stay private @State.
  func filesPresentation(
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

  func header(summary: DashboardReviewFilesSummary) -> some View {
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

  func topControlsPane(summary: DashboardReviewFilesSummary) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      header(summary: summary)
      searchField
      quickFilters
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
  }

  var searchField: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
        .accessibilityHidden(true)
      TextField(
        "Filter files",
        text: $filter.text,
        prompt: Text("Filter by path")
      )
      .textFieldStyle(.plain)
      if !filter.text.isEmpty {
        Button {
          filter.clearText()
        } label: {
          Image(systemName: "xmark.circle.fill")
            .imageScale(.small)
            .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
        }
        .harnessPlainButtonStyle()
        .accessibilityLabel("Clear file filter")
      }
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(HarnessMonitorTheme.ink.opacity(0.05))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(
          HarnessMonitorTheme.controlBorder.opacity(0.30),
          lineWidth: 1
        )
    )
  }

  var quickFilters: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        quickFilterChip(
          title: "Hide generated files",
          isSelected: filter.hideGenerated,
          help:
            "Hide files matching the generated-files patterns "
            + "(e.g. package-lock.json, yarn.lock, vendor/, dist/). "
            + "Configure patterns in Settings > Reviews > Files."
        ) {
          filter.hideGenerated.toggle()
        }

        quickFilterChip(
          title: "Unresolved",
          isSelected: onlyUnresolved,
          help: "Show only files with unresolved review conversations."
        ) {
          onlyUnresolved.toggle()
        }

        quickFilterChip(
          title: "Unviewed",
          isSelected: onlyUnviewed,
          help: "Show only files you have not viewed yet."
        ) {
          onlyUnviewed.toggle()
        }

        bucketFilterChip
      }
      .fixedSize(horizontal: true, vertical: false)
      .padding(.vertical, 1)
    }
    .scrollClipDisabled()
  }

  var bucketFilterChip: some View {
    Menu {
      Button("All file types") { bucketFilter = nil }
      Divider()
      ForEach(DashboardReviewFileBucket.allCases, id: \.self) { bucket in
        Button(bucket.rawValue) { bucketFilter = bucket }
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "line.3.horizontal.decrease")
          .imageScale(.small)
        Text(bucketFilter?.rawValue ?? "All file types")
          .lineLimit(1)
          .truncationMode(.tail)
        Image(systemName: "chevron.down")
          .imageScale(.small)
      }
      .scaledFont(.caption.weight(.semibold))
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .harnessFilterChipButtonStyle(isSelected: bucketFilter != nil)
    .harnessNativeFormControl()
    .accessibilityLabel("File type filter")
    .accessibilityValue(bucketFilter?.rawValue ?? "All file types")
    .accessibilityHint("Filters the file list by file type.")
  }

  func quickFilterChip(
    title: String,
    isSelected: Bool,
    help: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .imageScale(.small)
        Text(title)
          .lineLimit(1)
      }
      .scaledFont(.caption.weight(.semibold))
    }
    .harnessFilterChipButtonStyle(isSelected: isSelected)
    .harnessNativeFormControl()
    .accessibilityLabel(title)
    .accessibilityValue(isSelected ? "selected" : "not selected")
    .accessibilityHint(help)
    .help(help)
  }

  func fileList(
    presentation: DashboardReviewFilesModePresentation,
    viewModel: ReviewFilesViewModel,
    collapsedFolders: DashboardReviewFilesCollapsedFolders
  ) -> some View {
    let visiblePaths = expandedFilePaths(
      in: presentation.groups,
      collapsedFolders: collapsedFolders
    )
    return List(selection: selectedPathsBinding(viewModel: viewModel, visiblePaths: visiblePaths)) {
      ForEach(presentation.groups) { group in
        Section {
          if !collapsedFolders.contains(group.folder) {
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
              .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
              .listRowSeparator(.hidden)
            }
          }
        } header: {
          fileSectionHeader(
            for: group,
            isCollapsed: collapsedFolders.contains(group.folder)
          ) {
            toggleFolderCollapse(group.folder, collapsedFolders: collapsedFolders)
          }
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
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  func fileSectionHeader(
    for group: DashboardReviewFilesModeGroup,
    isCollapsed: Bool,
    onToggleCollapse: @escaping () -> Void
  ) -> some View {
    DashboardReviewFilesFolderSectionHeader(
      folder: group.folder,
      itemCount: group.rows.count,
      isCollapsed: isCollapsed,
      onToggleCollapse: onToggleCollapse
    )
  }

  func selectedPathsBinding(
    viewModel: ReviewFilesViewModel,
    visiblePaths: [String]
  ) -> Binding<Set<String>> {
    Binding(
      get: {
        listSelection.displayedSelection(fallbackPrimaryPath: viewModel.selectedPath)
          .intersection(Set(visiblePaths))
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
}
