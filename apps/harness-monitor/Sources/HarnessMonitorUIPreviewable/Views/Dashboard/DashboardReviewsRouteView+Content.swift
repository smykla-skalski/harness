import HarnessMonitorKit
import SwiftUI

extension DashboardReviewsRouteView {
  var contentPane: some View {
    Group {
      if routeDetailMode == .files, selectedItems.count <= 1, let item = primaryDetailItem {
        filesModeContentPane(for: item)
          .transition(.opacity)
      } else {
        reviewsOverviewContentPane
          .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .animation(.smooth(duration: 0.22), value: routeDetailMode)
  }

  @ViewBuilder
  private func reviewsGroupSection(_ group: DashboardReviewsRepositoryGroup) -> some View {
    switch group.kind {
    case .pinned:
      let isCollapsed = routeCollapsedSecondaryQueues.contains(.pinned)
      Section {
        if !isCollapsed {
          ForEach(group.items) { item in
            reviewRow(item, showsRepository: false)
          }
        }
      } header: {
        pinnedSectionHeader(
          itemCount: group.items.count,
          isCollapsed: isCollapsed
        )
      }
      .listSectionSeparator(.hidden)
    case .repository(let repository):
      Section {
        if !routeCollapsedRepositories.contains(repository) {
          ForEach(group.items) { item in
            reviewRow(item, showsRepository: false)
          }
        }
      } header: {
        repositorySectionHeader(
          repository,
          itemCount: group.items.count,
          busyPullRequestCount: group.items.count {
            isPullRequestRefreshing($0.pullRequestID)
          }
        )
      }
      .listSectionSeparator(.hidden)
    case .status, .author:
      EmptyView()
    case .smartInbox(let section):
      let isCollapsed = isSmartInboxSectionCollapsed(section)
      Section {
        if !isCollapsed {
          ForEach(group.items) { item in
            reviewRow(item, showsRepository: true)
          }
        }
      } header: {
        smartInboxSectionHeader(
          section,
          itemCount: group.items.count,
          isCollapsed: isCollapsed
        )
      }
      .listSectionSeparator(.hidden)
    }
  }

  private func isSmartInboxSectionCollapsed(
    _ section: DashboardReviewsSmartInboxSection
  ) -> Bool {
    guard let secondaryQueue = section.secondaryQueue else { return false }
    return routeCollapsedSecondaryQueues.contains(secondaryQueue)
  }

  var reviewsOverviewContentPane: some View {
    VStack(alignment: .leading, spacing: 14) {
      topControlsPane
      contentListPane
    }
    .padding(0)
  }

  var topControlsPane: some View {
    VStack(alignment: .leading, spacing: 14) {
      DashboardReviewsProvenanceBar(
        snapshot: routeProvenanceSnapshot,
        onRefresh: {
          Task { await reload(forceRefresh: true) }
        }
      )
      filterBar
      transientBannerZone
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
  }

  @ViewBuilder var contentListPane: some View {
    if let routeErrorMessage, !routeIsLoading {
      errorState(message: routeErrorMessage)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else {
      reviewsList
    }
  }

  var filterBar: some View {
    filterControls
  }

  var filterControls: some View {
    DashboardReviewsControlStrip(
      filterModeRaw: $filterModeRaw,
      sortModeRaw: $sortModeRaw,
      groupModeRaw: $groupModeRaw,
      needsMeOn: $needsMeOn,
      dependenciesOnlyOn: $dependenciesOnlyOn,
      showSnoozedOnly: $showSnoozedOnly,
      showAvatarsInRows: routeShowAvatarsInRowsBinding,
      showLabelsInRows: routeShowLabelsInRowsBinding,
      showLineCountersInRows: routeShowLineCountersInRowsBinding,
      showApprovalCountsInRows: routeShowApprovalCountsInRowsBinding,
      showTargetBranchInRows: routeShowTargetBranchInRowsBinding,
      showPullRequestNumberInRows: routeShowPullRequestNumberInRowsBinding,
      showPullRequestAgeInRows: routeShowPullRequestAgeInRowsBinding,
      wrapTitlesInRows: routeWrapTitlesInRowsBinding,
      hideSemanticPrefixesInRowTitles: routeSemanticPrefixesBinding,
      needsMeCount: routeNeedsMeCount,
      syncHealth: routeSyncHealth,
      onPastePullRequests: pasteReviewTextFromClipboard,
      onRetryFailedRepositories: {
        retryRepositories(routeSyncHealth.failedRepositories)
      },
      onRetryStaleRepositories: {
        retryRepositories(routeSyncHealth.staleRepositories)
      },
      onClearCache: {
        Task { await clearCacheAndReload() }
      }
    )
  }

  var reviewsList: some View {
    List(selection: routeSelectedIDsBinding) {
      if filteredItems.isEmpty, !routeIsLoading {
        emptyStateContent
          .frame(maxWidth: .infinity, minHeight: 280)
      } else if groupMode != .flat {
        ForEach(groupedItems) { group in
          reviewsGroupSection(group)
        }
      } else {
        ForEach(filteredItems) { item in
          reviewRow(item, showsRepository: true)
        }
      }
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsList)
    .contextMenu(forSelectionType: String.self) { selection in
      reviewSelectionContextMenu(for: selection)
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .disabled(routeIsLoading)
    .overlay {
      if routeIsLoading {
        ZStack {
          // Soft dim so the spinner reads as the foreground action while the
          // `.disabled` modifier above blocks taps on the underlying list.
          Color.black.opacity(0.18).ignoresSafeArea()
          ProgressView(reviewsLoadingLabel)
            .controlSize(.large)
        }
        .transition(.opacity)
      }
    }
  }

  var detailPane: some View {
    Group {
      if let routeErrorMessage, !routeIsLoading {
        errorState(message: routeErrorMessage)
      } else if routeDetailMode == .files, selectedItems.count <= 1, let item = primaryDetailItem {
        filesModeDetailPane(for: item)
          .transition(.opacity.combined(with: .scale(scale: 0.995)))
      } else if selectedItems.count > 1 {
        batchDetail
      } else if let item = primaryDetailItem {
        DashboardReviewDetailView(
          item: item,
          store: store,
          activity: activitySnapshot(for: item),
          repositoryLabels: routeResponse.repositoryLabels[item.repository] ?? [],
          viewerLogin: routeResponse.viewerLogin,
          filesAvailability: filesModeAvailability,
          detailMode: routeDetailModeBinding,
          showsProblemChecksOnly: routeShowsProblemChecksOnlyBinding,
          onDescriptionCheckboxError: { message in routeErrorMessage = message },
          onDescriptionCheckboxUpdated: {
            if let client = store.apiClient {
              scheduleAffectedRefresh(for: [item], using: client)
            }
          },
          onRerunCheck: { check in
            Task { await rerunCheck(check, for: item) }
          },
          onReRequestReview: { reviewer in
            Task { await reRequestReview(from: reviewer, on: item) }
          },
          actionBar: {
            reviewActionBar(items: [item])
          }
        )
      } else if routeIsLoading {
        ProgressView(reviewsLoadingLabel)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ContentUnavailableView {
          Label("Select a review", systemImage: "sidebar.right")
        } description: {
          Text("Review checks, approvals, labels, and native actions without leaving the dashboard")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsDetail)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  var batchDetail: some View {
    HarnessMonitorColumnScrollView(
      horizontalPadding: 24,
      verticalPadding: 24,
      constrainContentWidth: true,
      readableWidth: false,
      topScrollEdgeEffect: .soft,
      scrollSurfaceIdentifier: HarnessMonitorAccessibility.dashboardReviewsDetail,
      scrollSurfaceLabel: "Reviews detail"
    ) {
      VStack(alignment: .leading, spacing: 24) {
        DashboardReviewDetailCard(
          title: "\(selectedItems.count) selected",
          subtitle: "Run batch review actions across the current selection"
        ) {
          reviewActionBar(items: selectedItems)
        }
        DashboardReviewDetailSection(title: nil) {
          DashboardReviewBatchEligibilityPreview(items: selectedItems)
        }
      }
      .frame(maxWidth: reviewsDetailMaxWidth, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
    }
  }

}
