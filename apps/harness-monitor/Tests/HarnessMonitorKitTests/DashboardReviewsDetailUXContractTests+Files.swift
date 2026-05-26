import Foundation
import Testing

extension DashboardReviewsDetailUXContractTests {
  @Test("Files mode defers loading until the daemon is online")
  func filesModeDefersLoadingUntilTheDaemonIsOnline() throws {
    let filesMode = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/"
        + "DashboardReviewFilesModeContentPane.swift"
    )
    let load = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/"
        + "DashboardReviewFilesModeContentPane+Load.swift"
    )

    #expect(filesMode.contains(".task(id: loadKey)"))
    #expect(load.contains("ReviewTimelineTaskKey("))
    #expect(load.contains("isDaemonOnline: store.connectionState == .online"))
    #expect(load.contains("guard store.connectionState == .online else { return }"))
    #expect(load.contains("await store.prepareReviewFiles(pullRequestID: item.pullRequestID)"))
    #expect(load.contains("await store.prepareReviewTimeline(for: item)"))
  }

  @Test("Files mode exposes generated-file filtering alongside its quick filters")
  func filesModeExposesGeneratedFileFilteringAlongsideItsQuickFilters() throws {
    let filesMode = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/"
        + "DashboardReviewFilesModeContentPane.swift"
    )
    let filesModeLayout = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/"
        + "DashboardReviewFilesModeContentPane+Layout.swift"
    )
    let filesModeLoad = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/"
        + "DashboardReviewFilesModeContentPane+Load.swift"
    )
    let accessibility = try source(
      "Sources/HarnessMonitorUIPreviewable/Support/HarnessMonitorAccessibilityIDs.swift"
    )

    #expect(filesMode.contains("ViewThatFits(in: .horizontal)"))
    #expect(filesMode.contains("quickFiltersInlineRow("))
    #expect(filesMode.contains("quickFilterOverflowMenu("))
    #expect(filesModeLayout.contains("quickFilterChip("))
    #expect(filesMode.contains("bucketFilterChip"))
    #expect(filesMode.contains("dashboardReviewFilesFiltersMoreButton"))
    #expect(accessibility.contains("dashboardReviewFilesFiltersMoreButton"))
    #expect(filesModeLayout.contains(".harnessFilterChipButtonStyle(isSelected: isSelected)"))
    #expect(filesMode.contains(".harnessFilterChipButtonStyle(isSelected: bucketFilter != nil)"))
    #expect(filesMode.contains("\"Hide generated\""))
    #expect(filesMode.contains("\"Unresolved\""))
    #expect(filesMode.contains("\"Not viewed\""))
    #expect(filesMode.contains("Text(\"Filters\")"))
    #expect(filesMode.contains("filter.hideGenerated.toggle()"))
    #expect(filesMode.contains("onlyUnresolved.toggle()"))
    #expect(filesMode.contains("onlyUnviewed.toggle()"))
    #expect(!filesMode.contains("ScrollView(.horizontal, showsIndicators: false)"))
    #expect(!filesMode.contains("Toggle(isOn: $filter.hideGenerated)"))
    #expect(!filesMode.contains(".toggleStyle(.checkbox)"))
    #expect(filesMode.contains("preferences.update { $0.filesHideGenerated = newValue }"))
    #expect(filesModeLoad.contains("let nextFilter = currentFilterState"))
    #expect(filesModeLoad.contains("nextFilter.hideGenerated = prefs.filesHideGenerated"))
    #expect(filesModeLoad.contains("replaceFilterState(nextFilter)"))
  }

  @Test("Files mode header separates context from secondary actions")
  func filesModeHeaderSeparatesContextFromSecondaryActions() throws {
    let filesModeLayout = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/"
        + "DashboardReviewFilesModeContentPane+Layout.swift"
    )
    let accessibility = try source(
      "Sources/HarnessMonitorUIPreviewable/Support/HarnessMonitorAccessibilityIDs.swift"
    )

    #expect(filesModeLayout.contains("dashboardReviewDisplayedTitle("))
    #expect(filesModeLayout.contains("formatRelativeUpdatedAt(item.updatedAt)"))
    #expect(filesModeLayout.contains("Text(verbatim: \"#\\(item.number)\")"))
    #expect(filesModeLayout.contains("Text(verbatim: \"@\\(item.authorLogin)\")"))
    #expect(filesModeLayout.contains("Label(\"Review\", systemImage: \"ellipsis.circle\")"))
    #expect(filesModeLayout.contains("viewModel.selectNextUnviewed(in: presentation.visibleFiles)"))
    #expect(filesModeLayout.contains("filesVisibilitySummaryLabel(presentation)"))
    #expect(!filesModeLayout.contains("Text(verbatim: \"\\(item.title) #\\(item.number)\")"))
    #expect(filesModeLayout.contains("dashboardReviewFilesMoreButton"))
    #expect(accessibility.contains("dashboardReviewFilesMoreButton"))
  }

  @Test("Files detail header becomes file-scoped and uses chooser labels")
  func filesModeDetailHeaderBecomesFileScopedAndUsesChooserLabels() throws {
    let filesDetail = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewFilesModeDetailPane.swift"
    )
    let conversation = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/"
        + "DashboardReviewFilesModeDetailPane+Conversation.swift"
    )

    #expect(!filesDetail.contains("Button(action: onBack)"))
    #expect(!filesDetail.contains("Text(verbatim: \"\\(item.repository) #\\(item.number)\")"))
    #expect(!filesDetail.contains("Text(\"Layout\")"))
    #expect(filesDetail.contains("let title = isViewed ? \"Viewed\" : \"Mark viewed\""))
    #expect(filesDetail.contains("ForEach(FilesViewMode.allCases, id: \\.self) { mode in"))
    #expect(filesDetail.contains(".pickerStyle(.menu)"))
    #expect(!filesDetail.contains(".pickerStyle(.segmented)"))
    #expect(
      filesDetail.contains(
        "Label(title, systemImage: isViewed ? \"eye.fill\" : \"eye.slash\")"
      )
    )
    #expect(filesDetail.contains("title: \"Inline comment...\""))
    #expect(filesDetail.contains("Label(\"Actions\", systemImage: \"ellipsis.circle\")"))
    #expect(conversation.contains("Text(\"Conversations\")"))
    #expect(conversation.contains("conversationVisibilityMenuItem(.hidden)"))
    #expect(conversation.contains("conversationVisibilityMenuItem(.unresolved)"))
    #expect(conversation.contains("conversationVisibilityMenuItem(.all)"))
    #expect(!conversation.contains("Cycle inline conversations"))
  }

  @Test("Files detail diff surface uses the shared centered max-width container")
  func filesModeDetailDiffSurfaceUsesTheSharedCenteredMaxWidthContainer() throws {
    let filesDetail = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewFilesModeDetailPane.swift"
    )

    #expect(
      filesDetail.contains(
        ".frame(maxWidth: reviewsDetailMaxWidth, maxHeight: .infinity, alignment: .topLeading)"
      )
    )
    #expect(
      filesDetail.contains(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)")
    )
    #expect(filesDetail.contains(".padding(.horizontal, 28)"))
  }

  @Test("Files navigator labels folder counts and status indicators")
  func filesModeNavigatorLabelsFolderCountsAndStatusIndicators() throws {
    let support = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/"
        + "DashboardReviewFilesModeContentPane+Support.swift"
    )

    #expect(support.contains("itemCount == 1 ? \"1 file\" : \"\\(itemCount) files\""))
    #expect(support.contains("unresolvedThreadCount"))
    #expect(support.contains("changeCountLabel = \"+\\(file.additions) -\\(file.deletions)\""))
    #expect(support.contains("Image(systemName: \"text.bubble.fill\")"))
    #expect(
      support.contains(
        "Image(systemName: viewedState == .viewed ? \"checkmark.circle.fill\" : \"circle\")"
      )
    )
    #expect(support.contains("accessibilityValue(accessibilitySummary)"))
    #expect(!support.contains("Text(verbatim: \"\\(itemCount)\")"))
    #expect(
      !support.contains(
        "Image(systemName: viewedState == .viewed ? \"eye.fill\" : \"eye.slash\")"
      )
    )
  }

  @Test("Generated-file settings propagate live into the Files mode surface")
  func generatedFileSettingsPropagateLiveIntoTheFilesModeSurface() throws {
    let route = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/DashboardReviewsRouteView.swift"
    )
    let routeSync = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/"
        + "DashboardReviewsRouteView+StateSync.swift"
    )
    let filesMode = try source(
      "Sources/HarnessMonitorUIPreviewable/Views/Dashboard/"
        + "DashboardReviewFilesModeContentPane.swift"
    )

    #expect(
      route.contains("@State private var reviewsPreferencesStore = ReviewsPreferencesStore()")
    )
    #expect(route.contains(".environment(\\.reviewsPreferences, reviewsPreferencesStore)"))
    #expect(routeSync.contains("routeReviewsPreferencesStore.replace(nextPreferences.preferences)"))
    #expect(filesMode.contains(".onChange(of: preferences.compiledGeneratedPatternMatcher)"))
  }
}
