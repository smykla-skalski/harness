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
    let collapsedFolders = DashboardReviewFilesCollapsedFolders.decode(
      from: collapsedFoldersStorage
    )

    return VStack(alignment: .leading, spacing: 12) {
      topControlsPane(presentation: presentation)
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

  var currentFilterState: DashboardReviewFilesFilterState {
    filter
  }

  func replaceFilterState(_ nextFilter: DashboardReviewFilesFilterState) {
    filter = nextFilter
  }

  func cachedThreadIndex(for timeline: ReviewTimelineViewModel) -> DashboardReviewFileThreadIndex {
    threadIndexCache.index(for: timeline)
  }

  func noteStoredPrimarySelection(_ path: String) {
    listSelection.notePrimarySelection(path)
  }

  func displayedStoredListSelection(fallbackPrimaryPath: String?) -> Set<String> {
    listSelection.displayedSelection(fallbackPrimaryPath: fallbackPrimaryPath)
  }

  func collapseStoredListSelection(to primaryPath: String?) {
    listSelection.collapse(to: primaryPath)
  }

  func applyStoredListSelection(
    _ selection: Set<String>,
    fallbackPrimaryPath: String?,
    orderedVisiblePaths: [String]
  ) -> String? {
    listSelection.applySelection(
      selection,
      fallbackPrimaryPath: fallbackPrimaryPath,
      orderedVisiblePaths: orderedVisiblePaths
    )
  }

  func pruneStoredListSelection(
    visiblePaths: Set<String>,
    fallbackPrimaryPath: String?,
    orderedVisiblePaths: [String]
  ) -> String? {
    listSelection.prune(
      visiblePaths: visiblePaths,
      fallbackPrimaryPath: fallbackPrimaryPath,
      orderedVisiblePaths: orderedVisiblePaths
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

  var searchField: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
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
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
        .buttonStyle(.borderless)
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
    ViewThatFits(in: .horizontal) {
      quickFiltersInlineRow(
        showsHideGenerated: true,
        showsOnlyUnresolved: true,
        showsOnlyUnviewed: true,
        showsBucketFilter: true
      )
      quickFiltersInlineRow(
        showsHideGenerated: true,
        showsOnlyUnresolved: true,
        showsOnlyUnviewed: true,
        showsBucketFilter: false
      ) {
        quickFilterOverflowMenu(
          includesHideGenerated: false,
          includesOnlyUnresolved: false,
          includesOnlyUnviewed: false,
          includesBucketFilter: true
        )
      }
      quickFiltersInlineRow(
        showsHideGenerated: false,
        showsOnlyUnresolved: true,
        showsOnlyUnviewed: true,
        showsBucketFilter: false
      ) {
        quickFilterOverflowMenu(
          includesHideGenerated: true,
          includesOnlyUnresolved: false,
          includesOnlyUnviewed: false,
          includesBucketFilter: true
        )
      }
      quickFiltersInlineRow(
        showsHideGenerated: false,
        showsOnlyUnresolved: true,
        showsOnlyUnviewed: false,
        showsBucketFilter: false
      ) {
        quickFilterOverflowMenu(
          includesHideGenerated: true,
          includesOnlyUnresolved: false,
          includesOnlyUnviewed: true,
          includesBucketFilter: true
        )
      }
    }
  }

  @ViewBuilder
  func quickFiltersInlineRow<Trailing: View>(
    showsHideGenerated: Bool,
    showsOnlyUnresolved: Bool,
    showsOnlyUnviewed: Bool,
    showsBucketFilter: Bool,
    @ViewBuilder trailing: () -> Trailing = { EmptyView() }
  ) -> some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      if showsHideGenerated {
        quickFilterChip(
          title: "Hide generated",
          isSelected: filter.hideGenerated,
          help:
            "Hide files matching the generated-files patterns "
            + "(e.g. package-lock.json, yarn.lock, vendor/, dist/). "
            + "Configure patterns in Settings > Reviews > Files."
        ) {
          filter.hideGenerated.toggle()
        }
      }

      if showsOnlyUnresolved {
        quickFilterChip(
          title: "Unresolved only",
          isSelected: onlyUnresolved,
          help: "Show only files with unresolved review conversations."
        ) {
          onlyUnresolved.toggle()
        }
      }

      if showsOnlyUnviewed {
        quickFilterChip(
          title: "Unviewed only",
          isSelected: onlyUnviewed,
          help: "Show only files you have not viewed yet."
        ) {
          onlyUnviewed.toggle()
        }
      }

      if showsBucketFilter {
        bucketFilterChip
      }

      trailing()
    }
    .padding(.vertical, 1)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  var bucketFilterChip: some View {
    Menu {
      fileTypeFilterMenuContent
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "line.3.horizontal.decrease")
          .imageScale(.small)
        Text(bucketFilter.map { "Type: \($0.rawValue)" } ?? "File type")
          .lineLimit(1)
          .truncationMode(.tail)
        Image(systemName: "chevron.down")
          .imageScale(.small)
      }
      .scaledFont(.caption.weight(.semibold))
      .foregroundStyle(HarnessMonitorTheme.ink.opacity(bucketFilter != nil ? 1 : 0.94))
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .harnessFilterChipButtonStyle(isSelected: bucketFilter != nil)
    .harnessNativeFormControl()
    .accessibilityLabel("File type filter")
    .accessibilityValue(bucketFilter?.rawValue ?? "All file types")
    .accessibilityHint("Filters the file list by file type.")
  }

  @ViewBuilder private var fileTypeFilterMenuContent: some View {
    Button("All file types") { bucketFilter = nil }
    Divider()
    ForEach(DashboardReviewFileBucket.allCases, id: \.self) { bucket in
      Button(bucket.rawValue) { bucketFilter = bucket }
    }
  }

  func quickFilterOverflowMenu(
    includesHideGenerated: Bool,
    includesOnlyUnresolved: Bool,
    includesOnlyUnviewed: Bool,
    includesBucketFilter: Bool
  ) -> some View {
    let hasActiveOverflowedFilter =
      (includesHideGenerated && filter.hideGenerated)
      || (includesOnlyUnresolved && onlyUnresolved)
      || (includesOnlyUnviewed && onlyUnviewed)
      || (includesBucketFilter && bucketFilter != nil)

    return Menu {
      if includesHideGenerated {
        overflowToggleButton(title: "Hide generated", isSelected: filter.hideGenerated) {
          filter.hideGenerated.toggle()
        }
      }
      if includesOnlyUnresolved {
        overflowToggleButton(title: "Unresolved only", isSelected: onlyUnresolved) {
          onlyUnresolved.toggle()
        }
      }
      if includesOnlyUnviewed {
        overflowToggleButton(title: "Unviewed only", isSelected: onlyUnviewed) {
          onlyUnviewed.toggle()
        }
      }
      if includesBucketFilter {
        if includesHideGenerated || includesOnlyUnresolved || includesOnlyUnviewed {
          Divider()
        }
        Menu("File type") {
          fileTypeFilterMenuContent
        }
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "ellipsis.circle")
          .imageScale(.small)
        Text("More")
          .lineLimit(1)
      }
      .scaledFont(.caption.weight(.semibold))
      .foregroundStyle(HarnessMonitorTheme.ink.opacity(hasActiveOverflowedFilter ? 1 : 0.94))
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .harnessFilterChipButtonStyle(isSelected: hasActiveOverflowedFilter)
    .harnessNativeFormControl()
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewFilesFiltersMoreButton)
    .accessibilityLabel("More file filters")
    .accessibilityValue(hasActiveOverflowedFilter ? "Active" : "Inactive")
    .accessibilityHint("Shows additional file filters when space is limited.")
  }

  func overflowToggleButton(
    title: String,
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      if isSelected {
        Label(title, systemImage: "checkmark")
      } else {
        Label(title, systemImage: "circle")
      }
    }
  }

  func quickFilterChip(
    title: String,
    isSelected: Bool,
    help: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 6) {
        if isSelected {
          Image(systemName: "checkmark")
            .imageScale(.small)
        }
        Text(title)
          .lineLimit(1)
      }
      .scaledFont(.caption.weight(.semibold))
      .foregroundStyle(HarnessMonitorTheme.ink.opacity(isSelected ? 1 : 0.94))
    }
    .harnessFilterChipButtonStyle(isSelected: isSelected)
    .harnessNativeFormControl()
    .accessibilityLabel(title)
    .accessibilityValue(isSelected ? "selected" : "not selected")
    .accessibilityHint(help)
    .help(help)
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
