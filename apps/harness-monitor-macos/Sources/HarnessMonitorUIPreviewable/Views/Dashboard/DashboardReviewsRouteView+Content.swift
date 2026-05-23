import HarnessMonitorKit
import SwiftUI

extension DashboardReviewsRouteView {
  var contentPane: some View {
    VStack(alignment: .leading, spacing: 14) {
      filterBar
      DashboardReviewsProvenanceBar(
        snapshot: routeProvenanceSnapshot,
        onRefresh: {
          Task { await reload(forceRefresh: true) }
        }
      )
      inContentSearchField
      contentListPane
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(20)
  }

  /// In-content search field. The toolbar `.searchable` field remains for
  /// power users (Cmd+F); this surface gives sidebar-arrival users a visible
  /// affordance bound to the same `$searchText` storage.
  var inContentSearchField: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
        .accessibilityHidden(true)
      TextField(
        "Search reviews",
        text: $searchText,
        prompt: Text("Search repos, titles, authors, or labels")
      )
      .textFieldStyle(.plain)
      .accessibilityLabel("Search reviews")
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsInContentSearch)
      if !searchText.isEmpty {
        Button {
          searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .imageScale(.small)
            .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
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
      needsMeOn: routeNeedsMeOnBinding,
      dependenciesOnlyOn: routeDependenciesOnlyOnBinding,
      needsMeCount: routeResponse.items.lazy.filter(\.requiresAttention).count,
      syncHealth: routeSyncHealth,
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
        ContentUnavailableView {
          Label("No reviews", systemImage: "shippingbox")
        } description: {
          Text("Adjust your filters or configure a broader source scope")
        }
        .frame(maxWidth: .infinity, minHeight: 280)
      } else if groupMode == .repository {
        ForEach(groupedItems, id: \.repository) { group in
          Section {
            if !routeCollapsedRepositories.contains(group.repository) {
              ForEach(group.items) { item in
                reviewRow(item, showsRepository: false)
              }
            }
          } header: {
            repositorySectionHeader(
              group.repository,
              itemCount: group.items.count,
              busyPullRequestCount: group.items.count {
                isPullRequestRefreshing($0.pullRequestID)
              }
            )
          }
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
          ProgressView("Loading reviews…")
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
      } else if selectedItems.count > 1 {
        batchDetail
      } else if let item = primaryDetailItem {
        DashboardReviewDetailView(
          item: item,
          store: store,
          activity: activitySnapshot(for: item),
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
          actionBar: {
            reviewActionBar(items: [item])
          }
        )
      } else if routeIsLoading {
        ProgressView("Loading reviews…")
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

  func reviewRow(
    _ item: ReviewItem,
    showsRepository: Bool
  ) -> some View {
    DashboardReviewRow(
      item: item,
      showsRepository: showsRepository,
      isRefreshing: isPullRequestRefreshing(item.pullRequestID),
      actionTitle: pullRequestActionTitle(item.pullRequestID),
      updatedLabel: relativeUpdatedLabel(for: item)
    )
  }

  func repositorySectionHeader(
    _ repository: String,
    itemCount: Int,
    busyPullRequestCount: Int
  ) -> some View {
    DashboardReviewsRepositorySectionHeader(
      repository: repository,
      itemCount: itemCount,
      busyPullRequestCount: busyPullRequestCount,
      isCollapsed: routeCollapsedRepositories.contains(repository),
      scheduler: routeScheduler,
      onToggleCollapse: { toggleRepositoryCollapse(repository) },
      onRetryRepository: { retryRepositorySync(repository) }
    )
  }

  func reviewActionBar(items: [ReviewItem]) -> some View {
    DashboardReviewActionBar(
      items: items,
      availableLabels: dashboardReviewsAvailableLabels(
        repositoryLabels: routeResponse.repositoryLabels,
        items: items
      ),
      frequentNames: frequentLabelNames(for: items),
      showsDescriptions: normalizedPreferences.showLabelDescriptions,
      isBusy: items.contains { isPullRequestRefreshing($0.pullRequestID) },
      onApprove: { requestApproveOrConfirm(items: items) },
      onMerge: { requestMergeOrConfirm(items: items) },
      onRerunChecks: { trackInFlight(Task { await rerunChecks(items: items) }) },
      onRefresh: { refresh(items: items) },
      onSelectLabel: { name in trackInFlight(Task { await addLabel(name, to: items) }) },
      onCustomLabel: {
        routeLabelTargetItems = items
        routeLabelDraft = ""
        routeIsLabelSheetPresented = true
      },
      onCopyApprovalLinks: { copyApprovalLinks(for: items) },
      onAuto: {
        requestAuto(items: items)
      },
      onOpenItem: {
        if let item = items.first {
          openItem(item)
        }
      },
      onFixCI: {
        if let item = items.first {
          trackInFlight(Task { await fixCI(item: item) })
        }
      },
      onRebaseViaBot: {
        if let item = items.first,
          let bot = ReviewBot.detect(authorLogin: item.authorLogin)
        {
          trackInFlight(Task { await rebaseViaBot(item: item, bot: bot) })
        }
      }
    )
  }

  var labelSheet: some View {
    DashboardReviewsCustomLabelSheet(
      items: routeLabelTargetItems,
      suggestions: dashboardReviewsAvailableLabels(
        repositoryLabels: routeResponse.repositoryLabels,
        items: routeLabelTargetItems
      ),
      draft: routeLabelDraftBinding,
      onApply: { label in
        routeIsLabelSheetPresented = false
        let items = routeLabelTargetItems
        routeLabelTargetItems = []
        Task { await addLabel(label, to: items) }
      },
      onCancel: {
        routeLabelTargetItems = []
        routeIsLabelSheetPresented = false
      }
    )
  }
}
