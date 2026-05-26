import HarnessMonitorKit
import SwiftUI

extension DashboardReviewFilesModeContentPane {
  var displayTitle: String {
    dashboardReviewDisplayedTitle(
      item.title,
      hidesSemanticPrefix: preferences.snapshot.hideSemanticPrefixesInRowTitles
    )
  }

  var pullRequestURL: URL? {
    URL(string: item.url)
  }

  var authorProfileURL: URL? {
    URL(string: "https://github.com/\(item.authorLogin)")
  }

  var updatedContextLabel: String? {
    guard !item.updatedAt.isEmpty else { return nil }
    return "Updated \(formatRelativeUpdatedAt(item.updatedAt))"
  }

  func header(presentation: DashboardReviewFilesModePresentation) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        DashboardReviewDetailModeSwitcher(
          detailMode: $detailMode,
          filesAvailable: true
        )

        Spacer(minLength: HarnessMonitorTheme.spacingSM)

        headerActionsMenu(presentation: presentation)
      }

      VStack(alignment: .leading, spacing: 3) {
        Text(displayTitle)
          .font(
            HarnessMonitorTextSize.scaledFont(
              .system(.title3, design: .rounded, weight: .semibold),
              by: fontScale
            )
          )
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
          .help(item.title)

        headerMetadata
      }

      summaryRow(presentation: presentation)
    }
  }

  func topControlsPane(presentation: DashboardReviewFilesModePresentation) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      header(presentation: presentation)
      searchField
      quickFilters
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
  }

  private var headerMetadata: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 0) {
        Text(verbatim: item.repository)
          .lineLimit(1)
          .truncationMode(.middle)
          .layoutPriority(1)
        Text(" · ")
        Text(verbatim: "#\(item.number)")
        Text(" · ")
        Text(verbatim: "@\(item.authorLogin)")
        if let updatedContextLabel {
          Text(" · ")
          Text(updatedContextLabel)
        }
      }
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 0) {
          Text(verbatim: item.repository)
            .lineLimit(1)
            .truncationMode(.middle)
            .layoutPriority(1)
          Text(" · ")
          Text(verbatim: "#\(item.number)")
          Text(" · ")
          Text(verbatim: "@\(item.authorLogin)")
        }
        if let updatedContextLabel {
          Text(updatedContextLabel)
        }
      }
    }
    .scaledFont(.callout.weight(.semibold))
    .foregroundStyle(HarnessMonitorTheme.secondaryInk)
  }

  func headerActionsMenu(
    presentation: DashboardReviewFilesModePresentation
  ) -> some View {
    let hasVisibleUnviewed = presentation.visibleFiles.contains { file in
      (viewModel.viewedByPath[file.path] ?? file.viewerViewedState) != .viewed
    }
    let canOpenPullRequest = pullRequestURL != nil
    let canOpenAuthorProfile = authorProfileURL != nil

    return Menu {
      Button("Next unviewed file") {
        viewModel.selectNextUnviewed(in: presentation.visibleFiles)
      }
      .disabled(!hasVisibleUnviewed)

      if canOpenPullRequest || canOpenAuthorProfile {
        Divider()
      }
      if let pullRequestURL {
        Button("Open pull request") {
          openURL(pullRequestURL)
        }
      }
      if let authorProfileURL {
        Button("Open author profile") {
          openURL(authorProfileURL)
        }
      }
    } label: {
      Label("Review", systemImage: "ellipsis.circle")
        .lineLimit(1)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .controlSize(.small)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewFilesMoreButton)
    .accessibilityLabel("Review actions")
    .help("Review actions")
  }

  func summaryRow(
    presentation: DashboardReviewFilesModePresentation
  ) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        summaryMetric(
          title: filesVisibilitySummaryLabel(presentation),
          systemImage: "doc.on.doc"
        )
        summaryMetric(
          title: "\(presentation.visibleSummary.unviewed) not viewed",
          systemImage: "eye.slash"
        )
        if presentation.visibleSummary.unresolvedThreads > 0 {
          summaryMetric(
            title: "\(presentation.visibleSummary.unresolvedThreads) unresolved",
            systemImage: "text.bubble"
          )
        }
      }
      VStack(alignment: .leading, spacing: 4) {
        summaryMetric(
          title: filesVisibilitySummaryLabel(presentation),
          systemImage: "doc.on.doc"
        )
        HStack(spacing: 12) {
          summaryMetric(
            title: "\(presentation.visibleSummary.unviewed) not viewed",
            systemImage: "eye.slash"
          )
          if presentation.visibleSummary.unresolvedThreads > 0 {
            summaryMetric(
              title: "\(presentation.visibleSummary.unresolvedThreads) unresolved",
              systemImage: "text.bubble"
            )
          }
        }
      }
    }
  }

  func filesVisibilitySummaryLabel(
    _ presentation: DashboardReviewFilesModePresentation
  ) -> String {
    if presentation.visibleSummary.total == presentation.summary.total {
      return "\(presentation.summary.total) files"
    }
    return "Showing \(presentation.visibleSummary.total) of \(presentation.summary.total) files"
  }

  func summaryMetric(
    title: String,
    systemImage: String
  ) -> some View {
    Label(title, systemImage: systemImage)
      .scaledFont(.caption.weight(.semibold))
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .lineLimit(1)
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
        displayedStoredListSelection(fallbackPrimaryPath: viewModel.selectedPath)
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
}
