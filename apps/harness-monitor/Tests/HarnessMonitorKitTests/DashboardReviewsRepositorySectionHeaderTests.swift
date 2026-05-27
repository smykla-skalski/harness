import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard reviews repository section header")
struct DashboardReviewsRepositorySectionHeaderTests {
  @Test("idle + recently synced derives lastSynced status carrying the source date")
  func idleRecentlySyncedDerivesLastSynced() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let synced = now.addingTimeInterval(-90)
    let status = DashboardReviewsRepositorySectionHeaderStatus.derive(
      isSyncing: false,
      lastSyncedAt: synced,
      errorMessage: nil
    )
    #expect(status == .lastSynced(date: synced))
  }

  @Test("never synced derives neverSynced status when no error and not syncing")
  func neverSyncedDerivesNeverSynced() {
    let status = DashboardReviewsRepositorySectionHeaderStatus.derive(
      isSyncing: false,
      lastSyncedAt: nil,
      errorMessage: nil
    )
    #expect(status == .neverSynced)
  }

  @Test("syncing derives syncing status regardless of last-synced timestamp")
  func syncingDerivesSyncing() {
    let withHistory = DashboardReviewsRepositorySectionHeaderStatus.derive(
      isSyncing: true,
      lastSyncedAt: .now.addingTimeInterval(-60),
      errorMessage: nil
    )
    let withoutHistory = DashboardReviewsRepositorySectionHeaderStatus.derive(
      isSyncing: true,
      lastSyncedAt: nil,
      errorMessage: nil
    )
    #expect(withHistory == .syncing)
    #expect(withoutHistory == .syncing)
  }

  @Test("error wins over last-synced when not syncing")
  func errorWinsOverLastSyncedWhenNotSyncing() {
    let status = DashboardReviewsRepositorySectionHeaderStatus.derive(
      isSyncing: false,
      lastSyncedAt: .now.addingTimeInterval(-300),
      errorMessage: "boom"
    )
    #expect(status == .error(message: "boom"))
  }

  @Test("syncing wins over a recorded error so the status cluster shows progress")
  func syncingWinsOverError() {
    let status = DashboardReviewsRepositorySectionHeaderStatus.derive(
      isSyncing: true,
      lastSyncedAt: nil,
      errorMessage: "boom"
    )
    #expect(status == .syncing)
  }

  @Test("retry visibility is gated only by errorMessage presence")
  func retryVisibilityGatedOnlyByError() {
    #expect(
      dashboardReviewsRepositorySectionHeaderShouldShowRetry(errorMessage: nil) == false
    )
    #expect(
      dashboardReviewsRepositorySectionHeaderShouldShowRetry(errorMessage: "") == true
    )
    #expect(
      dashboardReviewsRepositorySectionHeaderShouldShowRetry(errorMessage: "boom") == true
    )
  }

  @Test("retry is disabled while a sync is in flight even though it stays visible")
  func retryIsDisabledWhileSyncing() {
    #expect(dashboardReviewsRepositorySectionHeaderRetryIsEnabled(isSyncing: false) == true)
    #expect(dashboardReviewsRepositorySectionHeaderRetryIsEnabled(isSyncing: true) == false)
  }

  @Test("busy accessibility label pluralizes the working PR count")
  func busyAccessibilityLabelPluralizes() {
    #expect(
      dashboardReviewsRepositorySectionHeaderBusyAccessibilityLabel(busyPullRequestCount: 1)
        == "1 pull request updating"
    )
    #expect(
      dashboardReviewsRepositorySectionHeaderBusyAccessibilityLabel(busyPullRequestCount: 3)
        == "3 pull requests updating"
    )
  }

  @Test("error + syncing matrix keeps retry visible but disabled and prefers syncing status")
  func errorPlusSyncingMatrix() {
    let status = DashboardReviewsRepositorySectionHeaderStatus.derive(
      isSyncing: true,
      lastSyncedAt: nil,
      errorMessage: "boom"
    )
    #expect(status == .syncing)
    #expect(
      dashboardReviewsRepositorySectionHeaderShouldShowRetry(errorMessage: "boom") == true
    )
    #expect(dashboardReviewsRepositorySectionHeaderRetryIsEnabled(isSyncing: true) == false)
  }

  @Test("error + idle matrix shows error status, retry visible and enabled")
  func errorIdleMatrix() {
    let status = DashboardReviewsRepositorySectionHeaderStatus.derive(
      isSyncing: false,
      lastSyncedAt: nil,
      errorMessage: "network down"
    )
    #expect(status == .error(message: "network down"))
    #expect(
      dashboardReviewsRepositorySectionHeaderShouldShowRetry(errorMessage: "network down") == true
    )
    #expect(dashboardReviewsRepositorySectionHeaderRetryIsEnabled(isSyncing: false) == true)
  }

  @Test("context menu offers repository sync and reuses the retry action")
  func contextMenuOffersRepositorySync() throws {
    let repositoryHeaderSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRepositorySectionHeader.swift"
    )

    #expect(repositoryHeaderSource.contains("Button(\"Sync Repository\")"))
    #expect(repositoryHeaderSource.contains("onSyncRepository()"))
    #expect(repositoryHeaderSource.contains("Button(action: onSyncRepository)"))
  }

  @Test("busy + idle matrix derives lastSynced with no retry, busy accessibility carries the count")
  func busyIdleMatrix() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let synced = now.addingTimeInterval(-30)
    let status = DashboardReviewsRepositorySectionHeaderStatus.derive(
      isSyncing: false,
      lastSyncedAt: synced,
      errorMessage: nil
    )
    #expect(status == .lastSynced(date: synced))
    #expect(
      dashboardReviewsRepositorySectionHeaderShouldShowRetry(errorMessage: nil) == false
    )
    #expect(
      dashboardReviewsRepositorySectionHeaderBusyAccessibilityLabel(busyPullRequestCount: 2)
        == "2 pull requests updating"
    )
  }

  @Test("reviews section headers use shared full-width chrome without custom background styling")
  func reviewsSectionHeadersUseSharedFullWidthChrome() throws {
    let repositoryHeaderSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRepositorySectionHeader.swift"
    )
    let pinnedHeaderSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteView+PinnedHeader.swift"
    )
    let contentSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteView+Content.swift"
    )

    let repositoryHasSharedChrome = repositoryHeaderSource.contains(
      "DashboardReviewsSectionHeaderChrome("
    )
    let pinnedHeaderForwardsPresentationMode = pinnedHeaderSource.contains(
      "presentationMode: presentationMode"
    )
    let repositoryUsesZeroInsets = repositoryHeaderSource.contains(".listRowInsets(.all, 0)")
    let repositoryUsesClearRowBackground = repositoryHeaderSource.contains(
      ".listRowBackground(Color.clear)"
    )
    let repositorySupportsPresentationModes = repositoryHeaderSource.contains(
      "DashboardReviewsSectionHeaderPresentationMode"
    )
    let repositoryUsesRowPaddingMetric = repositoryHeaderSource.contains(
      "DashboardReviewsVisualMetrics.reviewRowHorizontalPadding"
    )
    let repositoryDrawsBottomDivider = !repositoryHeaderSource.contains(
      ".overlay(alignment: .bottom)"
    )
    let repositoryUsesMaterialBackground = !repositoryHeaderSource.contains(
      "DashboardReviewsStickyHeaderMaterialBackground"
    )
    let repositoryUsesVisualEffectView = !repositoryHeaderSource.contains("NSVisualEffectView")
    let repositoryUsesHeaderMaterial = !repositoryHeaderSource.contains(
      "effectView.material = .headerView"
    )
    let repositoryUsesWithinWindowBlend = !repositoryHeaderSource.contains(
      "effectView.blendingMode = .withinWindow"
    )
    let repositoryUsesSeparatorColor = !repositoryHeaderSource.contains(
      "dividerColor: NSColor.separatorColor"
    )
    let repositoryUsesPlainErrorState = repositoryHeaderSource.contains(
      "Label(\"Error\", systemImage: \"exclamationmark.triangle\")"
    )
    let repositoryUsesPlainNeverSyncedState = repositoryHeaderSource.contains(
      "Text(\"Never synced\")"
    )
    let repositoryRemovedHeaderPill = !repositoryHeaderSource.contains(
      "DashboardReviewsRepositoryHeaderPill"
    )
    let repositoryRemovedGlassPill = !repositoryHeaderSource.contains("harnessControlPillGlass")
    let repositoryRemovedAlphaSeparator = !repositoryHeaderSource.contains(
      "separatorColor.withAlphaComponent"
    )
    let repositoryRemovedChromePalette = !repositoryHeaderSource.contains(
      "DashboardReviewsSectionHeaderChromePalette"
    )
    let repositoryRemovedGroupRowObserver = !repositoryHeaderSource.contains(
      "observe(\\.isGroupRowStyle"
    )
    let repositoryRemovedGroupRowObservationStorage = !repositoryHeaderSource.contains(
      "groupRowStyleObservations"
    )
    let repositoryRemovedRowLookup = !repositoryHeaderSource.contains("rowView(atRow: rowIndex")
    let repositoryRemovedRowProbe = !repositoryHeaderSource.contains(
      "DashboardReviewsSectionHeaderRowBackgroundProbe("
    )
    let repositoryRemovedTableRowMutation = !repositoryHeaderSource.contains("NSTableRowView")
    let repositoryRemovedLayerInjection = !repositoryHeaderSource.contains("insertSublayer")
    let repositoryKeepsNativeFloatingRows = !repositoryHeaderSource.contains(
      "tableView.floatsGroupRows = false"
    )
    let repositoryRemovedScrollBackdropInjection = !repositoryHeaderSource.contains(
      "scrollView.addSubview(backdrop, positioned: .above, relativeTo: scrollView.contentView)"
    )
    let repositoryAvoidsSwiftUIMaterialFill = !repositoryHeaderSource.contains(
      ".fill(.regularMaterial)"
    )
    let contentConfiguresListProbe = !contentSource.contains(
      "DashboardReviewsListTableConfigurationProbe()"
    )
    let contentUsesStickyPreferenceKey = !contentSource.contains(
      "DashboardReviewsStickyHeaderMarkerPreferenceKey.self"
    )
    let contentMarksStickyElements = !contentSource.contains(".dashboardReviewsStickyHeaderMarker(")
    let contentUsesStickyCoordinateSpace = !contentSource.contains(
      ".coordinateSpace(name: DashboardReviewsStickyHeaderCoordinateSpace.name)"
    )
    let contentUsesStickyPresentation = !contentSource.contains(
      "dashboardReviewsStickyHeaderPresentation(from: markers)"
    )
    let contentRendersStickyOverlayMode = !contentSource.contains(
      "presentationMode: .stickyOverlay"
    )
    let contentDefinesStickyBandBottom = !contentSource.contains(
      "let stickyBandBottom = topInset + defaultHeaderHeight"
    )
    let contentFiltersRowsAgainstStickyBand = !contentSource.contains(
      "marker.frame.maxY > stickyBandBottom"
    )
    let contentSuppressesVisibleHeaders = !contentSource.contains(
      "topMarker.frame.maxY > topInset"
    )

    #expect(repositoryHasSharedChrome)
    #expect(pinnedHeaderForwardsPresentationMode)
    #expect(repositoryUsesZeroInsets)
    #expect(repositoryUsesClearRowBackground)
    #expect(repositorySupportsPresentationModes)
    #expect(repositoryUsesRowPaddingMetric)
    #expect(repositoryDrawsBottomDivider)
    #expect(repositoryUsesMaterialBackground)
    #expect(repositoryUsesVisualEffectView)
    #expect(repositoryUsesHeaderMaterial)
    #expect(repositoryUsesWithinWindowBlend)
    #expect(repositoryUsesSeparatorColor)
    #expect(repositoryUsesPlainErrorState)
    #expect(repositoryUsesPlainNeverSyncedState)
    #expect(repositoryRemovedHeaderPill)
    #expect(repositoryRemovedGlassPill)
    #expect(repositoryRemovedAlphaSeparator)
    #expect(repositoryRemovedChromePalette)
    #expect(repositoryRemovedGroupRowObserver)
    #expect(repositoryRemovedGroupRowObservationStorage)
    #expect(repositoryRemovedRowLookup)
    #expect(repositoryRemovedRowProbe)
    #expect(repositoryRemovedTableRowMutation)
    #expect(repositoryRemovedLayerInjection)
    #expect(repositoryKeepsNativeFloatingRows)
    #expect(repositoryRemovedScrollBackdropInjection)
    #expect(repositoryAvoidsSwiftUIMaterialFill)
    #expect(contentConfiguresListProbe)
    #expect(contentUsesStickyPreferenceKey)
    #expect(contentMarksStickyElements)
    #expect(contentUsesStickyCoordinateSpace)
    #expect(contentUsesStickyPresentation)
    #expect(contentRendersStickyOverlayMode)
    #expect(contentDefinesStickyBandBottom)
    #expect(contentFiltersRowsAgainstStickyBand)
    #expect(contentSuppressesVisibleHeaders)
    let hiddenSectionSeparators =
      contentSource.components(separatedBy: ".listSectionSeparator(.hidden)").count - 1
    #expect(hiddenSectionSeparators >= 2)
    #expect(
      !repositoryHeaderSource.contains(
        ".listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))"
      )
    )
    #expect(
      !pinnedHeaderSource.contains(
        ".listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))"
      )
    )
  }
}
