import Foundation
import CoreGraphics
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

  @Test("sticky overlay stays hidden while the real header is fully visible")
  func stickyOverlayHiddenWhileHeaderVisible() {
    let presentation = dashboardReviewsStickyHeaderPresentation(
      from: [
        DashboardReviewsStickyHeaderMarker(
          kind: .header,
          headerID: .repository("kong/harness"),
          frame: CGRect(x: 0, y: 0, width: 300, height: 32)
        ),
        DashboardReviewsStickyHeaderMarker(
          kind: .row("pr-1"),
          headerID: .repository("kong/harness"),
          frame: CGRect(x: 0, y: 32, width: 300, height: 64)
        )
      ]
    )
    #expect(presentation == nil)
  }

  @Test("sticky overlay follows the top visible row when the header has scrolled off")
  func stickyOverlayUsesTopVisibleRow() {
    let presentation = dashboardReviewsStickyHeaderPresentation(
      from: [
        DashboardReviewsStickyHeaderMarker(
          kind: .row("pr-1"),
          headerID: .repository("kong/harness"),
          frame: CGRect(x: 0, y: 6, width: 300, height: 64)
        ),
        DashboardReviewsStickyHeaderMarker(
          kind: .header,
          headerID: .repository("kong-mesh/mesh"),
          frame: CGRect(x: 0, y: 120, width: 300, height: 32)
        )
      ]
    )
    #expect(
      presentation
        == DashboardReviewsStickyHeaderPresentation(
          headerID: .repository("kong/harness"),
          offsetY: 0
        )
    )
  }

  @Test("next header pushes the sticky overlay upward")
  func nextHeaderPushesStickyOverlay() {
    let presentation = dashboardReviewsStickyHeaderPresentation(
      from: [
        DashboardReviewsStickyHeaderMarker(
          kind: .row("pr-1"),
          headerID: .repository("kong/harness"),
          frame: CGRect(x: 0, y: 4, width: 300, height: 64)
        ),
        DashboardReviewsStickyHeaderMarker(
          kind: .header,
          headerID: .repository("kong-mesh/mesh"),
          frame: CGRect(x: 0, y: 20, width: 300, height: 32)
        )
      ]
    )
    #expect(
      presentation
        == DashboardReviewsStickyHeaderPresentation(
          headerID: .repository("kong/harness"),
          offsetY: -12
        )
    )
  }

  @Test("reviews section headers use shared full-width chrome")
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

    #expect(
      repositoryHeaderSource.contains(
        "DashboardReviewsSectionHeaderChrome("
      )
    )
    #expect(
      pinnedHeaderSource.contains(
        "presentationMode: presentationMode"
      )
    )
    #expect(
      repositoryHeaderSource.contains(
        ".listRowInsets(.all, 0)"
      )
    )
    #expect(repositoryHeaderSource.contains(".listRowBackground(Color.clear)"))
    #expect(repositoryHeaderSource.contains("DashboardReviewsSectionHeaderRowBackgroundProbe("))
    #expect(repositoryHeaderSource.contains("NSTableRowView"))
    #expect(repositoryHeaderSource.contains("insertSublayer"))
    #expect(repositoryHeaderSource.contains("NSColor.windowBackgroundColor"))
    #expect(repositoryHeaderSource.contains("NSColor(HarnessMonitorTheme.accent)"))
    #expect(repositoryHeaderSource.contains("NSColor(HarnessMonitorTheme.ink)"))
    #expect(repositoryHeaderSource.contains("tintLayerName"))
    #expect(repositoryHeaderSource.contains("tableView.floatsGroupRows = false"))
    #expect(repositoryHeaderSource.contains("DashboardReviewsSectionHeaderPresentationMode"))
    #expect(repositoryHeaderSource.contains("DashboardReviewsVisualMetrics.reviewRowHorizontalPadding"))
    #expect(repositoryHeaderSource.contains("viewWillMove(toSuperview newSuperview: NSView?)"))
    #expect(repositoryHeaderSource.contains(".overlay(alignment: .bottom)"))
    #expect(repositoryHeaderSource.contains("DashboardReviewsStickyHeaderMaterialBackground()"))
    #expect(repositoryHeaderSource.contains("NSVisualEffectView"))
    #expect(repositoryHeaderSource.contains("nsView.material = .headerView"))
    #expect(repositoryHeaderSource.contains("nsView.blendingMode = .withinWindow"))
    #expect(repositoryHeaderSource.contains("dividerColor: NSColor.separatorColor"))
    #expect(repositoryHeaderSource.contains("y: max(rowView.bounds.height - 1, 0)"))
    #expect(repositoryHeaderSource.contains("firstIndex(where: { $0 === existing })"))
    #expect(repositoryHeaderSource.contains("Label(\"Error\", systemImage: \"exclamationmark.triangle\")"))
    #expect(repositoryHeaderSource.contains("Text(\"Never synced\")"))
    #expect(!repositoryHeaderSource.contains("DashboardReviewsRepositoryHeaderPill"))
    #expect(!repositoryHeaderSource.contains("harnessControlPillGlass"))
    #expect(!repositoryHeaderSource.contains("separatorColor.withAlphaComponent"))
    #expect(!repositoryHeaderSource.contains("observe(\\.isGroupRowStyle"))
    #expect(!repositoryHeaderSource.contains("groupRowStyleObservations"))
    #expect(!repositoryHeaderSource.contains("rowView(atRow: rowIndex"))
    #expect(!repositoryHeaderSource.contains(".fill(.regularMaterial)"))
    #expect(contentSource.contains("DashboardReviewsListTableConfigurationProbe()"))
    #expect(contentSource.contains("DashboardReviewsStickyHeaderMarkerPreferenceKey.self"))
    #expect(contentSource.contains(".dashboardReviewsStickyHeaderMarker("))
    #expect(contentSource.contains(".coordinateSpace(name: DashboardReviewsStickyHeaderCoordinateSpace.name)"))
    #expect(contentSource.contains("dashboardReviewsStickyHeaderPresentation(from: markers)"))
    #expect(contentSource.contains("presentationMode: .stickyOverlay"))
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
