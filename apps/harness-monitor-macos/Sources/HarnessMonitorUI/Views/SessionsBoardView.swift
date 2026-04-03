import HarnessMonitorKit
import SwiftUI

struct SessionsBoardView: View {
  let store: HarnessMonitorStore

  private var isLoading: Bool {
    store.isDaemonActionInFlight || store.isRefreshing || store.connectionState == .connecting
  }

  var body: some View {
    HarnessMonitorColumnScrollView(constrainContentWidth: true) {
      VStack(alignment: .leading, spacing: 24) {
        if store.sessions.isEmpty {
          SessionsBoardOnboardingCard(
            connectionState: store.connectionState,
            isLaunchAgentInstalled: store.daemonStatus?.launchAgent.installed == true,
            hasSessions: !store.sessions.isEmpty,
            isLoading: isLoading,
            startDaemon: startDaemon,
            installLaunchAgent: installLaunchAgent,
            refresh: refresh
          )
        }
        SessionsBoardRecentSessionsSection(
          sessions: store.sessions,
          selectSession: selectSession
        )
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .foregroundStyle(HarnessMonitorTheme.ink)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionsBoardRoot)
  }

  private func selectSession(_ sessionID: String) {
    store.primeSessionSelection(sessionID)
    Task {
      await store.selectSession(sessionID)
    }
  }

  private func startDaemon() async {
    await store.startDaemon()
  }

  private func installLaunchAgent() async {
    await store.installLaunchAgent()
  }

  private func refresh() async {
    await store.refresh()
  }
}
