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
      storedPreferences: "",
      connectionState: .idle
    )
    let connecting = DashboardDependenciesReloadTaskKey(
      storedPreferences: "",
      connectionState: .connecting
    )
    let online = DashboardDependenciesReloadTaskKey(
      storedPreferences: "",
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
    #expect(source.contains(".task(id: reloadTaskKey)"))
    #expect(!source.contains(".task(id: storedPreferences)"))
    #expect(!source.contains("runAutoRefreshLoop"))
    #expect(source.contains("await startScheduler(forceRefreshAll: forceRefresh)"))
    #expect(!source.contains("refreshToken +="))
    #expect(!source.contains("let refreshToken"))
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

  @Test("error helper rewrites GitHub 401 messages into actionable copy")
  func errorHelperRewritesGitHubUnauthorizedIntoActionableCopy() {
    let envelope =
      #"{"error":{"code":"WORKFLOW_IO","message":"dependency-updates github "#
      + #"request failed: GitHub API returned 401 Unauthorized: Bad credentials. "#
      + #"Check that the GitHub token is valid"}}"#
    let apiError = HarnessMonitorAPIError.server(code: 400, message: envelope)

    #expect(
      dashboardDependenciesErrorMessage(for: apiError)
        == dashboardDependenciesGitHubAuthFailureMessage
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
        == dashboardDependenciesGitHubAuthFailureMessage
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
        == dashboardDependenciesDecodingFailureMessage
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
}
