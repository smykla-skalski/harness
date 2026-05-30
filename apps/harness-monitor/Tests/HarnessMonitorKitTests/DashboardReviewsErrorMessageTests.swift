import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard reviews error message and copy")
struct DashboardReviewsErrorMessageTests {
  @Test("renamed GitHub 401 symbol exposes the actionable Settings > Secrets copy")
  func renamedGitHubAuthFailureMessageMentionsSettingsSecrets() {
    #expect(dashboardReviewsGitHubAuthFailureMessage.contains("Settings > Secrets"))
    #expect(dashboardReviewsGitHubAuthFailureMessage.contains("401"))
    #expect(dashboardReviewsGitHubAuthFailureMessage.contains("Update it"))
  }

  @Test("renamed decoding-failure symbol explains the daemon/version-skew remedy")
  func renamedDecodingFailureMessageExplainsDaemonRestart() {
    #expect(dashboardReviewsDecodingFailureMessage.contains("restart the daemon"))
    #expect(dashboardReviewsDecodingFailureMessage.contains("different versions"))
  }

  @Test("Settings Secrets section title matches the user-facing string in error copy")
  func errorCopySettingsSectionTitleMatchesSidebar() {
    // The GitHub auth error tells the user to update the token in
    // "Settings > Secrets". If the Settings sidebar ever renames that
    // section (e.g. to "Credentials" or "Tokens"), the copy goes stale
    // silently. This test pins both surfaces to the same canonical name.
    let canonicalTitle = SettingsSection.secrets.title
    #expect(canonicalTitle == "Secrets")
    #expect(
      dashboardReviewsGitHubAuthFailureMessage.contains("Settings > \(canonicalTitle)")
    )
  }

  @Test("missing-client error mentions Settings Diagnostics so users can self-recover")
  func missingClientErrorMentionsDiagnostics() {
    let state = dashboardReviewsMissingClientState(
      backgroundRefresh: false,
      connectionState: .idle
    )
    guard case .error(let message) = state else {
      Issue.record("Expected error state, got \(state)")
      return
    }
    #expect(message.contains("Settings > Diagnostics"))
    #expect(message.contains("local sync engine"))
    #expect(!message.contains("daemon client"))
    // The Settings sidebar must still expose a Diagnostics section so the
    // recovery hint is reachable.
    #expect(SettingsSection.diagnostics.title == "Diagnostics")
  }

  @Test("loading label falls back to bare copy when the scheduler has no tracked repos")
  func loadingLabelFallsBackWithoutSchedulerProgress() {
    #expect(
      dashboardReviewsLoadingLabel(totalRepositories: 0, syncedRepositories: 0)
        == "Loading reviews…"
    )
  }

  @Test("loading label reports synced/total when the scheduler is tracking repositories")
  func loadingLabelReportsSyncedOverTotalWhenSchedulerTracking() {
    #expect(
      dashboardReviewsLoadingLabel(totalRepositories: 5, syncedRepositories: 0)
        == "Loading reviews… (0 / 5 repositories)"
    )
    #expect(
      dashboardReviewsLoadingLabel(totalRepositories: 5, syncedRepositories: 3)
        == "Loading reviews… (3 / 5 repositories)"
    )
  }

  @Test("loading label clamps synced count when it exceeds total or is negative")
  func loadingLabelClampsOutOfRangeSyncedCount() {
    // The scheduler can briefly report a synced count larger than total
    // during a repository-set change (state drops a repository between
    // ticks). Clamp so we never render "(7 / 5)".
    #expect(
      dashboardReviewsLoadingLabel(totalRepositories: 5, syncedRepositories: 7)
        == "Loading reviews… (5 / 5 repositories)"
    )
    #expect(
      dashboardReviewsLoadingLabel(totalRepositories: 5, syncedRepositories: -2)
        == "Loading reviews… (0 / 5 repositories)"
    )
  }

  @Test("filter-aware empty-state branch is wired in the route content view")
  func filterAwareEmptyStateBranchIsWiredInContent() throws {
    let source = try contentSource()

    // The route now switches between two ContentUnavailableView variants
    // via the hasActiveFilters guard. Pin both literals plus the helper.
    #expect(source.contains("var hasActiveFilters: Bool"))
    #expect(source.contains("func clearAllFilters()"))
    #expect(source.contains("emptyStateContent"))
    #expect(source.contains("No reviews match your filters"))
    #expect(source.contains("Try widening the criteria."))
    #expect(source.contains("Clear filters"))
    #expect(source.contains("Configure scope"))
    #expect(source.contains("openSettingsSection(.repositories)"))
    // Original empty-state copy still ships for the no-filter branch.
    #expect(source.contains("No reviews"))
    #expect(source.contains("Adjust your filters or configure a broader source scope"))
  }

  @Test("loading overlay uses the progress-aware label helper")
  func loadingOverlayUsesProgressAwareLabel() throws {
    let source = try contentSource()

    #expect(source.contains("ProgressView(reviewsLoadingLabel)"))
    #expect(source.contains("var reviewsLoadingLabel: String"))
    #expect(source.contains("dashboardReviewsLoadingLabel("))
    // The bare literal must no longer survive in the route content.
    #expect(!source.contains(#"ProgressView("Loading reviews…")"#))
  }

  @Test("error-state ContentUnavailableView attaches the daemon glossary help")
  func errorStateAttachesDaemonGlossaryHelp() throws {
    let source = try helpersSource()

    #expect(source.contains(".help("))
    #expect(source.contains("local sync engine"))
    #expect(source.contains("Settings > Diagnostics"))
  }

  private func contentSource() throws -> String {
    // The content view was split for the file-length cap: the empty-state
    // branch, filter helpers, and the loading-label accessor now live in the
    // +ContentRows companion. Union-read both so every pinned literal resolves.
    let base = try routeSource(named: "DashboardReviewsRouteView+Content.swift")
    let rows = try routeSource(named: "DashboardReviewsRouteView+ContentRows.swift")
    return base + "\n" + rows
  }

  private func helpersSource() throws -> String {
    try routeSource(named: "DashboardReviewsRouteView+DetailHelpers.swift")
  }

  private func routeSource(named fileName: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL =
      repoRoot
      .appendingPathComponent(
        "apps/harness-monitor/Sources/HarnessMonitorUIPreviewable/Views/Dashboard"
      )
      .appendingPathComponent(fileName)
    return try String(contentsOf: sourceURL, encoding: .utf8)
  }
}
