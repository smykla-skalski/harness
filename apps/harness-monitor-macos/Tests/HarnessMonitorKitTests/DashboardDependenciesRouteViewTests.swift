import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard dependencies route view")
struct DashboardDependenciesRouteViewTests {
  @Test("missing-client state keeps the route loading while the daemon connects")
  func missingClientStateKeepsLoadingWhileConnecting() {
    #expect(
      dashboardDependenciesMissingClientState(
        backgroundRefresh: false,
        connectionState: .connecting
      ) == .loading
    )
    #expect(
      dashboardDependenciesMissingClientState(
        backgroundRefresh: true,
        connectionState: .connecting
      ) == .ignore
    )
    #expect(
      dashboardDependenciesMissingClientState(
        backgroundRefresh: false,
        connectionState: .idle
      ) == .error("The dependencies route needs a daemon client")
    )
    #expect(
      dashboardDependenciesMissingClientState(
        backgroundRefresh: false,
        connectionState: .offline("Daemon stopped")
      ) == .error("The dependencies route needs a daemon client")
    )
  }

  @Test("reload task key changes when connection state changes")
  func reloadTaskKeyChangesWhenConnectionStateChanges() {
    let idle = DashboardDependenciesReloadTaskKey(
      preferencesSignature: "",
      connectionState: .idle
    )
    let connecting = DashboardDependenciesReloadTaskKey(
      preferencesSignature: "",
      connectionState: .connecting
    )
    let online = DashboardDependenciesReloadTaskKey(
      preferencesSignature: "",
      connectionState: .online
    )

    #expect(idle != connecting)
    #expect(connecting != online)
  }

  @Test("route source reloads from the connection-aware task key")
  func routeSourceReloadsFromConnectionAwareTaskKey() throws {
    let source = try routeSource()

    #expect(source.contains("private var reloadTaskKey: DashboardDependenciesReloadTaskKey"))
    #expect(source.contains("connectionState: store.connectionState"))
    #expect(source.contains("preferencesSignature: resolvedPreferences.cacheHash"))
    #expect(source.contains(".task(id: reloadTaskKey)"))
    #expect(!source.contains(".task(id: storedPreferences)"))
    #expect(!source.contains("runAutoRefreshLoop"))
    #expect(source.contains("await startScheduler(forceRefreshAll: forceRefresh)"))
    #expect(!source.contains("refreshToken +="))
    #expect(!source.contains("let refreshToken"))
  }

  @Test("route source caches decoded preferences off the SwiftUI body path")
  func routeSourceCachesDecodedPreferencesOffTheSwiftUIBodyPath() throws {
    let source = try routeSource()
    let cacheSource = try routeSource(named: "DashboardDependenciesRouteView+Cache.swift")
    let schedulerSource = try routeSource(named: "DashboardDependenciesRouteView+Scheduler.swift")

    #expect(source.contains("struct DashboardDependenciesResolvedPreferences"))
    #expect(source.contains("@State private var resolvedPreferences"))
    #expect(
      source.contains("var routeResolvedPreferences: DashboardDependenciesResolvedPreferences"))
    #expect(source.contains(".onChange(of: storedPreferences, initial: true)"))
    #expect(source.contains("syncPreferencesFromStorage(newValue)"))
    #expect(
      !source.contains("get { DashboardDependenciesPreferences.decode(from: storedPreferences) }"))
    #expect(
      !source.contains(
        "var normalizedPreferences: DashboardDependenciesPreferences {\n    preferences.normalized()"
      )
    )
    #expect(cacheSource.contains("routeResolvedPreferences.cacheHash"))
    #expect(schedulerSource.contains("explicitRepositories: preferences.repositories"))
    #expect(schedulerSource.contains("preferences: preferences"))
  }

  @Test("route source keeps dependency network decode off the view actor")
  func routeSourceKeepsDependencyNetworkDecodeOffTheViewActor() throws {
    let source = try routeSource()
    let refreshSource = try routeSource(named: "DashboardDependenciesRouteView+Refresh.swift")
    let schedulerSource = try routeSource(named: "DashboardDependenciesScheduler.swift")

    #expect(source.contains("enum DashboardDependenciesRemoteLoader"))
    #expect(source.contains("Task.detached(priority: .userInitiated)"))
    #expect(schedulerSource.contains("DashboardDependenciesRemoteLoader.query("))
    #expect(!schedulerSource.contains("client.queryDependencyUpdates(request: request)"))
    #expect(refreshSource.contains("DashboardDependenciesRemoteLoader.refresh("))
  }

  @Test("dashboard preview exercises dependency alert rendering")
  func dashboardPreviewExercisesDependencyAlertRendering() throws {
    let source = try previewSource(named: "PreviewDashboardDependenciesRouteView.swift")

    #expect(source.contains("> ℹ️ **Note**"))
    #expect(source.contains("This PR body was truncated due to platform limits."))
  }

  @Test("error helper rewrites GitHub 401 messages into actionable copy")
  func errorHelperRewritesGitHubUnauthorizedIntoActionableCopy() {
    let envelope =
      #"{"error":{"code":"WORKFLOW_IO","message":"dependency-updates github "#
      + #"request failed: GitHub API returned 401 Unauthorized: Bad credentials. "#
      + #"Check that the GitHub token is valid"}}"#
    let apiError = HarnessMonitorAPIError.server(code: 400, message: envelope)

    #expect(
      dashboardDependenciesErrorMessage(for: apiError)
        == dashboardDepsGitHubAuthFailureMessage
    )
  }

  @Test("error helper detects GitHub 401 messages in non-API errors")
  func errorHelperDetectsGitHubUnauthorizedInTransportLikeErrors() {
    struct LegacyTransportError: LocalizedError {
      var errorDescription: String? {
        "dependency-updates github request failed: GitHub API returned 401 Unauthorized"
      }
    }

    #expect(
      dashboardDependenciesErrorMessage(for: LegacyTransportError())
        == dashboardDepsGitHubAuthFailureMessage
    )
  }

  @Test("error helper rewrites DecodingError into version-mismatch copy")
  func errorHelperRewritesDecodingErrorIntoVersionMismatchCopy() {
    let decodingError = DecodingError.valueNotFound(
      String.self,
      DecodingError.Context(codingPath: [], debugDescription: "missing payload")
    )

    #expect(
      dashboardDependenciesErrorMessage(for: decodingError)
        == dashboardDepsDecodingFailureMessage
    )
  }

  @Test("error helper passes through unknown localized errors")
  func errorHelperPassesThroughUnknownLocalizedErrors() {
    struct UnknownError: LocalizedError {
      var errorDescription: String? { "everything is on fire" }
    }

    #expect(
      dashboardDependenciesErrorMessage(for: UnknownError()) == "everything is on fire"
    )
  }

  @Test("check rows expose links context menu and severity sorting")
  func checkRowsExposeLinksContextMenuAndSeveritySorting() throws {
    let visualSource = try routeSource(named: "DashboardDependenciesVisualComponents.swift")
    let presentationSource = try routeSource(named: "DashboardDependenciesCheckPresentation.swift")
    let detailSource = try routeSource(named: "DashboardDependencyDetailView.swift")
    let actionsSource = try routeSource(named: "DashboardDependenciesRouteView+Actions.swift")

    #expect(visualSource.contains("sortedChecks"))
    #expect(visualSource.contains("lhs.displayPriority"))
    #expect(presentationSource.contains("var displayPriority: Int"))
    #expect(visualSource.contains("arrow.up.forward.square"))
    #expect(visualSource.contains("Open Check Run"))
    #expect(visualSource.contains("Copy Check URL"))
    #expect(visualSource.contains("Rerun Check"))
    #expect(visualSource.contains("check.detailsWebURL"))
    #expect(detailSource.contains("onRerunCheck: (DependencyUpdateCheck) -> Void"))
    #expect(actionsSource.contains("func rerunCheck(_ check: DependencyUpdateCheck"))
  }

  @Test("rerun check controls explain unavailable state")
  func rerunCheckControlsExplainUnavailableState() throws {
    let actionBarSource = try routeSource(named: "DashboardDependencyActionBar.swift")
    let modelSource = try modelSource(named: "HarnessMonitorDependenciesExtensions.swift")

    #expect(actionBarSource.contains("rerunChecksHelp"))
    #expect(actionBarSource.contains(".accessibilityHint(rerunChecksHelp)"))
    #expect(modelSource.contains("rerunChecksUnavailableReason"))
    #expect(modelSource.contains("rerunUnavailableReason"))
    #expect(modelSource.contains("GitHub did not provide a check suite ID"))
  }

  private func routeSource() throws -> String {
    try routeSource(named: "DashboardDependenciesRouteView.swift")
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
        "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/Dashboard"
      )
      .appendingPathComponent(fileName)
    return try String(contentsOf: sourceURL, encoding: .utf8)
  }

  private func previewSource(named fileName: String) throws -> String {
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
        "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/Dashboard/Previews"
      )
      .appendingPathComponent(fileName)
    return try String(contentsOf: sourceURL, encoding: .utf8)
  }

  private func modelSource(named fileName: String) throws -> String {
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
        "apps/harness-monitor-macos/Sources/HarnessMonitorKit/Models"
      )
      .appendingPathComponent(fileName)
    return try String(contentsOf: sourceURL, encoding: .utf8)
  }
}
