import HarnessKit
import SwiftUI

struct PreferencesDetailContent: View {
  let section: PreferencesSection
  let snapshot: PreferencesSnapshot
  @Binding var themeMode: HarnessThemeMode
  let reconnect: HarnessAsyncActionButton.Action
  let refreshDiagnostics: HarnessAsyncActionButton.Action
  let startDaemon: HarnessAsyncActionButton.Action
  let installLaunchAgent: HarnessAsyncActionButton.Action
  let removeLaunchAgent: HarnessAsyncActionButton.Action

  var body: some View {
    switch section {
    case .general:
      PreferencesGeneralSection(
        themeMode: $themeMode,
        endpoint: snapshot.endpoint,
        version: snapshot.version,
        launchAgentState: snapshot.launchAgentState,
        launchAgentCaption: snapshot.launchAgentCaption,
        cacheEntryCount: snapshot.cacheEntryCount,
        sessionCount: snapshot.sessionCount,
        startedAt: snapshot.startedAt,
        lastError: snapshot.lastError,
        lastAction: snapshot.lastAction,
        isLoading: snapshot.isGeneralActionsLoading,
        reconnect: reconnect,
        refreshDiagnostics: refreshDiagnostics,
        startDaemon: startDaemon,
        installLaunchAgent: installLaunchAgent,
        removeLaunchAgent: removeLaunchAgent
      )
    case .connection:
      PreferencesConnectionSection(
        isConnecting: snapshot.isConnecting,
        isDiagnosticsRefreshInFlight: snapshot.isDiagnosticsRefreshInFlight,
        reconnect: reconnect,
        refreshDiagnostics: refreshDiagnostics,
        metrics: snapshot.metrics,
        events: snapshot.events
      )
    case .diagnostics:
      PreferencesDiagnosticsSection(
        launchAgent: snapshot.launchAgent,
        tokenPresent: snapshot.tokenPresent,
        projectCount: snapshot.projectCount,
        sessionCount: snapshot.sessionCount,
        lastEvent: snapshot.lastEvent,
        paths: snapshot.paths,
        recentEvents: snapshot.recentEvents
      )
    }
  }
}
