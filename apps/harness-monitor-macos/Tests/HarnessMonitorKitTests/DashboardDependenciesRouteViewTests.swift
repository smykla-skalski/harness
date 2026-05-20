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
      refreshToken: 0,
      connectionState: .idle
    )
    let connecting = DashboardDependenciesReloadTaskKey(
      storedPreferences: "",
      refreshToken: 0,
      connectionState: .connecting
    )
    let online = DashboardDependenciesReloadTaskKey(
      storedPreferences: "",
      refreshToken: 0,
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
  }

  private func routeSource() throws -> String {
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
      .appendingPathComponent("DashboardDependenciesRouteView.swift")
    return try String(contentsOf: sourceURL, encoding: .utf8)
  }
}
