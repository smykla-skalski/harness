import HarnessMonitorKit
import SwiftUI

struct SessionsBoardView: View {
  let store: HarnessMonitorStore
  @AppStorage("harnessMonitor.board.onboardingDismissed")
  private var isOnboardingDismissed = false

  private var isLoading: Bool {
    store.isDaemonActionInFlight || store.isRefreshing || store.connectionState == .connecting
  }

  var body: some View {
    HarnessMonitorColumnScrollView(constrainContentWidth: true) {
      VStack(alignment: .leading, spacing: 24) {
        if !isOnboardingDismissed {
          SessionsBoardOnboardingCard(
            connectionState: store.connectionState,
            isLaunchAgentInstalled: store.daemonStatus?.launchAgent.installed == true,
            hasSessions: !store.sessions.isEmpty,
            isLoading: isLoading,
            startDaemon: startDaemon,
            installLaunchAgent: installLaunchAgent,
            refresh: refresh,
            dismiss: { isOnboardingDismissed = true }
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
    Task { await store.selectSession(sessionID) }
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

#Preview("Sessions Board - Dashboard") {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded)

  SessionsBoardView(store: store)
    .frame(width: 980, height: 720)
}

#Preview("Sessions Board - Empty") {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .empty)

  SessionsBoardView(store: store)
    .frame(width: 980, height: 720)
}
