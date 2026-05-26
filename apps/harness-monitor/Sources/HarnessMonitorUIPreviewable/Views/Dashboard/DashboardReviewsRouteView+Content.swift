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
      inContentSearchField
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
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
        .harnessPlainButtonStyle()
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
      showAvatarsInRows: routeShowAvatarsInRowsBinding,
      showLabelsInRows: routeShowLabelsInRowsBinding,
      showLineCountersInRows: routeShowLineCountersInRowsBinding,
      showPullRequestNumberInRows: routeShowPullRequestNumberInRowsBinding,
      showPullRequestAgeInRows: routeShowPullRequestAgeInRowsBinding,
      wrapTitlesInRows: routeWrapTitlesInRowsBinding,
      hideSemanticPrefixesInRowTitles: routeSemanticPrefixesBinding,
      needsMeCount: routeNeedsMeCount,
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
        emptyStateContent
          .frame(maxWidth: .infinity, minHeight: 280)
      } else if groupMode == .repository {
        ForEach(groupedItems) { group in
          switch group.kind {
          case .pinned:
            Section {
              ForEach(group.items) { item in
                reviewRow(item, showsRepository: false)
                  .dashboardReviewsStickyHeaderMarker(
                    kind: .row(item.pullRequestID),
                    headerID: .pinned
                  )
              }
            } header: {
              pinnedSectionHeader(itemCount: group.items.count)
                .dashboardReviewsStickyHeaderMarker(kind: .header, headerID: .pinned)
            }
            .listSectionSeparator(.hidden)
          case .repository(let repository):
            Section {
              if !routeCollapsedRepositories.contains(repository) {
                ForEach(group.items) { item in
                  reviewRow(item, showsRepository: false)
                    .dashboardReviewsStickyHeaderMarker(
                      kind: .row(item.pullRequestID),
                      headerID: .repository(repository)
                    )
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
              .dashboardReviewsStickyHeaderMarker(
                kind: .header,
                headerID: .repository(repository)
              )
            }
            .listSectionSeparator(.hidden)
          case .status, .author:
            EmptyView()
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
    .background {
      DashboardReviewsListTableConfigurationProbe()
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
    .coordinateSpace(name: DashboardReviewsStickyHeaderCoordinateSpace.name)
    .overlayPreferenceValue(
      DashboardReviewsStickyHeaderMarkerPreferenceKey.self,
      alignment: .topLeading
    ) { markers in
      stickyHeaderOverlay(from: markers)
    }
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

  @ViewBuilder
  private func stickyHeaderOverlay(
    from markers: [DashboardReviewsStickyHeaderMarker]
  ) -> some View {
    if let presentation = dashboardReviewsStickyHeaderPresentation(from: markers) {
      switch presentation.headerID {
      case .pinned:
        if let pinnedGroup = groupedItems.first(where: { $0.kind == .pinned }) {
          pinnedSectionHeader(
            itemCount: pinnedGroup.items.count,
            presentationMode: .stickyOverlay
          )
          .offset(y: presentation.offsetY)
          .zIndex(1)
        }
      case .repository(let repository):
        if let repositoryGroup = groupedItems.first(where: { group in
          if case .repository(let value) = group.kind {
            return value == repository
          }
          return false
        }) {
          repositorySectionHeader(
            repository,
            itemCount: repositoryGroup.items.count,
            busyPullRequestCount: repositoryGroup.items.count {
              isPullRequestRefreshing($0.pullRequestID)
            },
            presentationMode: .stickyOverlay
          )
          .offset(y: presentation.offsetY)
          .zIndex(1)
        }
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

enum DashboardReviewsStickyHeaderID: Hashable, Sendable {
  case pinned
  case repository(String)
}

enum DashboardReviewsStickyHeaderMarkerKind: Hashable, Sendable {
  case header
  case row(String)
}

struct DashboardReviewsStickyHeaderMarker: Equatable, Sendable, Identifiable {
  let kind: DashboardReviewsStickyHeaderMarkerKind
  let headerID: DashboardReviewsStickyHeaderID
  let frame: CGRect

  var id: String {
    switch kind {
    case .header:
      switch headerID {
      case .pinned:
        return "header:pinned"
      case .repository(let repository):
        return "header:repository:\(repository)"
      }
    case .row(let pullRequestID):
      return "row:\(pullRequestID)"
    }
  }
}

struct DashboardReviewsStickyHeaderPresentation: Equatable, Sendable {
  let headerID: DashboardReviewsStickyHeaderID
  let offsetY: CGFloat
}

func dashboardReviewsStickyHeaderPresentation(
  from markers: [DashboardReviewsStickyHeaderMarker],
  topInset: CGFloat = 0,
  defaultHeaderHeight: CGFloat = 32
) -> DashboardReviewsStickyHeaderPresentation? {
  let stickyBandBottom = topInset + defaultHeaderHeight
  let visibleMarkers = markers.filter { marker in
    guard marker.frame.height > 0 else { return false }
    switch marker.kind {
    case .header:
      return marker.frame.maxY > topInset
    case .row:
      return marker.frame.maxY > stickyBandBottom
    }
  }
  guard
    let topMarker = visibleMarkers.min(by: { lhs, rhs in
      lhs.frame.minY < rhs.frame.minY
    })
  else {
    return nil
  }

  if case .header = topMarker.kind, topMarker.frame.maxY > topInset {
    return nil
  }

  let visibleHeaderMarkers = visibleMarkers.filter { marker in
    if case .header = marker.kind {
      return true
    }
    return false
  }
  let headerHeight =
    visibleHeaderMarkers.first(where: { $0.headerID == topMarker.headerID })?.frame.height
    ?? visibleHeaderMarkers.first?.frame.height
    ?? defaultHeaderHeight
  let nextHeaderMinY = visibleHeaderMarkers
    .map(\.frame.minY)
    .filter { $0 > topInset }
    .min()
  let offsetY = nextHeaderMinY.map { min(0, $0 - topInset - headerHeight) } ?? 0
  return DashboardReviewsStickyHeaderPresentation(
    headerID: topMarker.headerID,
    offsetY: offsetY
  )
}

private enum DashboardReviewsStickyHeaderCoordinateSpace {
  static let name = "harness.dashboard.reviews.sticky-header"
}

private struct DashboardReviewsStickyHeaderMarkerPreferenceKey: PreferenceKey {
  static let defaultValue: [DashboardReviewsStickyHeaderMarker] = []

  static func reduce(
    value: inout [DashboardReviewsStickyHeaderMarker],
    nextValue: () -> [DashboardReviewsStickyHeaderMarker]
  ) {
    value.append(contentsOf: nextValue())
  }
}

private struct DashboardReviewsStickyHeaderMarkerModifier: ViewModifier {
  let kind: DashboardReviewsStickyHeaderMarkerKind
  let headerID: DashboardReviewsStickyHeaderID

  func body(content: Content) -> some View {
    content.background {
      GeometryReader { proxy in
        Color.clear.preference(
          key: DashboardReviewsStickyHeaderMarkerPreferenceKey.self,
          value: [
            DashboardReviewsStickyHeaderMarker(
              kind: kind,
              headerID: headerID,
              frame: proxy.frame(in: .named(DashboardReviewsStickyHeaderCoordinateSpace.name))
            )
          ]
        )
      }
    }
  }
}

extension View {
  fileprivate func dashboardReviewsStickyHeaderMarker(
    kind: DashboardReviewsStickyHeaderMarkerKind,
    headerID: DashboardReviewsStickyHeaderID
  ) -> some View {
    modifier(DashboardReviewsStickyHeaderMarkerModifier(kind: kind, headerID: headerID))
  }
}
