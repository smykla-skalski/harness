import HarnessMonitorKit
import SwiftUI

extension DashboardDependenciesRouteView {
  var contentPane: some View {
    VStack(alignment: .leading, spacing: 14) {
      filterBar
      DashboardDependenciesProvenanceBar(
        snapshot: routeProvenanceSnapshot,
        onRefresh: {
          Task { await reload(forceRefresh: true) }
        }
      )
      contentListPane
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(20)
  }

  @ViewBuilder var contentListPane: some View {
    if let routeErrorMessage, !routeIsLoading {
      errorState(message: routeErrorMessage)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else {
      dependenciesList
    }
  }

  var filterBar: some View {
    filterControls
  }

  var filterControls: some View {
    DashboardDependenciesControlStrip(
      filterModeRaw: $filterModeRaw,
      sortModeRaw: $sortModeRaw,
      groupModeRaw: $groupModeRaw,
      needsMeCount: routeResponse.items.lazy.filter(\.requiresAttention).count,
      syncHealth: routeSyncHealth,
      onRefresh: {
        Task { await reload(forceRefresh: true) }
      },
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

  var dependenciesList: some View {
    List(selection: routeSelectedIDsBinding) {
      if filteredItems.isEmpty, !routeIsLoading {
        ContentUnavailableView {
          Label("No dependency updates", systemImage: "shippingbox")
        } description: {
          Text("Adjust your filters or configure a broader source scope")
        }
        .frame(maxWidth: .infinity, minHeight: 280)
      } else if groupMode == .repository {
        ForEach(groupedItems, id: \.repository) { group in
          Section {
            if !routeCollapsedRepositories.contains(group.repository) {
              ForEach(group.items) { item in
                dependencyRow(item, showsRepository: false)
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
          dependencyRow(item, showsRepository: true)
        }
      }
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDependenciesList)
    .contextMenu(forSelectionType: String.self) { selection in
      dependencySelectionContextMenu(for: selection)
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .overlay {
      if routeIsLoading {
        ProgressView("Loading dependencies…")
          .controlSize(.large)
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
        DashboardDependencyDetailView(
          item: item,
          store: store,
          activity: activitySnapshot(for: item),
          provenance: routeProvenanceSnapshot,
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
            dependencyActionBar(items: [item])
          }
        )
      } else if routeIsLoading {
        ProgressView("Loading dependencies…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ContentUnavailableView {
          Label("Select a dependency update", systemImage: "sidebar.right")
        } description: {
          Text("Review checks, approvals, labels, and native actions without leaving the dashboard")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDependenciesDetail)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  var batchDetail: some View {
    HarnessMonitorColumnScrollView(
      horizontalPadding: 24,
      verticalPadding: 24,
      constrainContentWidth: true,
      readableWidth: false,
      topScrollEdgeEffect: .soft,
      scrollSurfaceIdentifier: HarnessMonitorAccessibility.dashboardDependenciesDetail,
      scrollSurfaceLabel: "Dependencies detail"
    ) {
      VStack(alignment: .leading, spacing: 24) {
        DashboardDependencyDetailCard(
          title: "\(selectedItems.count) selected",
          subtitle: "Run batch dependency actions across the current selection"
        ) {
          dependencyActionBar(items: selectedItems)
        }
        DashboardDependencyDetailSection(title: nil) {
          DashboardDependencyBatchEligibilityPreview(items: selectedItems)
        }
      }
      .frame(maxWidth: dependenciesDetailMaxWidth, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
    }
  }

  func dependencyRow(
    _ item: DependencyUpdateItem,
    showsRepository: Bool
  ) -> some View {
    DashboardDependencyRow(
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
    DashboardDependenciesRepositorySectionHeader(
      repository: repository,
      itemCount: itemCount,
      busyPullRequestCount: busyPullRequestCount,
      isCollapsed: routeCollapsedRepositories.contains(repository),
      scheduler: routeScheduler,
      onToggleCollapse: { toggleRepositoryCollapse(repository) },
      onRetryRepository: { retryRepositorySync(repository) }
    )
  }

  func dependencyActionBar(items: [DependencyUpdateItem]) -> some View {
    DashboardDependencyActionBar(
      items: items,
      availableLabels: dashboardDependenciesAvailableLabels(
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
          let bot = DependencyUpdateBot.detect(authorLogin: item.authorLogin)
        {
          trackInFlight(Task { await rebaseViaBot(item: item, bot: bot) })
        }
      }
    )
  }

  var labelSheet: some View {
    DashboardDependenciesCustomLabelSheet(
      items: routeLabelTargetItems,
      suggestions: dashboardDependenciesAvailableLabels(
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
