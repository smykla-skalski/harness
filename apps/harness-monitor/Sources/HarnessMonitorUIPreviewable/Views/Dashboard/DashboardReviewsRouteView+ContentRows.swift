import HarnessMonitorKit
import SwiftUI

extension DashboardReviewsRouteView {
  func reviewRow(
    _ item: ReviewItem,
    showsRepository: Bool
  ) -> some View {
    DashboardReviewRow(
      item: item,
      showsRepository: showsRepository,
      isSelected: routeSelectedIDs.contains(item.pullRequestID),
      isPinned: isPullRequestPinned(item.pullRequestID),
      isRefreshing: isPullRequestRefreshing(item.pullRequestID),
      actionTitle: pullRequestActionTitle(item.pullRequestID),
      updatedLabel: relativeUpdatedLabel(for: item),
      repositoryLabelByName: routeLabelMenuDataByRepository[item.repository]?.labelByName ?? [:],
      showsAvatars: normalizedPreferences.showAvatarsInRows,
      showsLabels: normalizedPreferences.showLabelsInRows,
      showsLineCounters: normalizedPreferences.showLineCountersInRows,
      showsPullRequestNumber: normalizedPreferences.showPullRequestNumberInRows,
      showsPullRequestAge: normalizedPreferences.showPullRequestAgeInRows,
      wrapsTitle: normalizedPreferences.wrapTitlesInRows,
      titleMaximumLines: normalizedPreferences.rowTitleMaximumLines,
      hidesSemanticPrefixesInTitle: normalizedPreferences.hideSemanticPrefixesInRowTitles
    )
  }

  func repositorySectionHeader(
    _ repository: String,
    itemCount: Int,
    busyPullRequestCount: Int,
    presentationMode: DashboardReviewsSectionHeaderPresentationMode = .sectionRow
  ) -> some View {
    DashboardReviewsRepositorySectionHeader(
      repository: repository,
      itemCount: itemCount,
      busyPullRequestCount: busyPullRequestCount,
      isCollapsed: routeCollapsedRepositories.contains(repository),
      isPinned: routePinnedRepositories.contains(repository),
      scheduler: routeScheduler,
      onToggleCollapse: { toggleRepositoryCollapse(repository) },
      onTogglePin: { toggleRepositoryPin(repository) },
      onSyncRepository: { syncRepository(repository) },
      presentationMode: presentationMode
    )
  }

  func pinnedSectionHeader(
    itemCount: Int,
    presentationMode: DashboardReviewsSectionHeaderPresentationMode = .sectionRow
  ) -> some View {
    DashboardReviewsPinnedSectionHeader(
      itemCount: itemCount,
      presentationMode: presentationMode
    )
  }

  func smartInboxSectionHeader(
    _ title: String,
    itemCount: Int,
    presentationMode: DashboardReviewsSectionHeaderPresentationMode = .sectionRow
  ) -> some View {
    DashboardReviewsSectionHeaderChrome(presentationMode: presentationMode) {
      HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
        Text(title)
          .foregroundStyle(HarnessMonitorTheme.ink)
          .font(.subheadline.weight(.semibold))
          .lineLimit(1)
        Text(verbatim: "·")
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Text(verbatim: "\(itemCount)")
          .monospacedDigit()
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(1)
      }
    }
  }

  func reviewActionBar(items: [ReviewItem]) -> some View {
    let pinIntent =
      dashboardReviewsPinSelectionIntent(
        items: items,
        pinnedPullRequestIDs: routePinnedPullRequests.pullRequestIDs
      ) ?? .pin
    return DashboardReviewActionBar(
      items: items,
      viewerLogin: routeResponse.viewerLogin,
      availableLabels: dashboardReviewsAvailableLabels(
        repositoryLabels: routeResponse.repositoryLabels,
        items: items
      ),
      frequentNames: frequentLabelNames(for: items),
      showsDescriptions: normalizedPreferences.showLabelDescriptions,
      isBusy: items.contains { isPullRequestRefreshing($0.pullRequestID) },
      pinActionTitle: dashboardReviewsPinSelectionMenuTitle(
        itemCount: items.count,
        intent: pinIntent
      ),
      pinActionSystemImage: pinIntent == .pin ? "pin.fill" : "pin.slash",
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
      onTogglePinnedSelection: {
        togglePinnedSelection(items: items)
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

  /// True when any reviews filter is currently narrowing the visible items.
  /// Drives the filter-aware variant of the empty state so we can offer
  /// "Clear filters" instead of the generic "configure a broader scope" copy.
  var hasActiveFilters: Bool {
    needsMeOn || dependenciesOnlyOn || filterModeRaw != DashboardReviewsFilterMode.all.rawValue
      || !searchText.isEmpty
  }

  /// Reset every filter back to its default. Used by the empty-state
  /// "Clear filters" action so a one-click recovery is always available.
  func clearAllFilters() {
    filterModeRaw = DashboardReviewsFilterMode.all.rawValue
    needsMeOn = false
    dependenciesOnlyOn = false
    searchText = ""
  }

  /// Loading copy. When the per-repo scheduler has tracked state we surface
  /// the synced/total progress so the spinner doesn't read as "nothing is
  /// happening" on cold launches with many repositories.
  var reviewsLoadingLabel: String {
    dashboardReviewsLoadingLabel(
      totalRepositories: routeScheduler.states.count,
      syncedRepositories: routeScheduler.states.values.lazy.filter { $0.lastSyncedAt != nil }.count
    )
  }

  @ViewBuilder var emptyStateContent: some View {
    if hasActiveFilters {
      ContentUnavailableView {
        Label(
          "No reviews match your filters",
          systemImage: "line.3.horizontal.decrease.circle"
        )
      } description: {
        Text("Try widening the criteria.")
      } actions: {
        Button("Clear filters") {
          clearAllFilters()
        }
        Button("Configure scope") {
          openSettingsSection(.repositories)
        }
      }
    } else {
      ContentUnavailableView {
        Label("No reviews", systemImage: "shippingbox")
      } description: {
        Text("Adjust your filters or configure a broader source scope")
      }
    }
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
