import Foundation
import HarnessMonitorKit
import SwiftUI

struct DashboardAgentsPreviewSurface: View {
  let state: DashboardAgentBrowserViewState
  let initialTerminalDetail: DashboardTerminalAgentDetail?
  let initialAcpDetail: DashboardAcpAgentDetail?
  let initialCodexDetail: DashboardCodexAgentDetail?
  private let store: HarnessMonitorStore
  private let history: GlobalWindowNavigationHistory
  private let selectionDefaults: UserDefaults

  @MainActor
  init(
    state: DashboardAgentBrowserViewState,
    selectedIdentity: DashboardAgentIdentity? = nil,
    selectionRawValue: String? = nil,
    decisions: [Decision] = [],
    bucketSession: SessionSummary? = nil,
    initialTerminalDetail: DashboardTerminalAgentDetail? = nil,
    initialAcpDetail: DashboardAcpAgentDetail? = nil,
    initialCodexDetail: DashboardCodexAgentDetail? = nil
  ) {
    self.state = state
    self.initialTerminalDetail = initialTerminalDetail
    self.initialAcpDetail = initialAcpDetail
    self.initialCodexDetail = initialCodexDetail
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded)
    if let bucketSession { _ = store.sessionIndex.applySessionSummary(bucketSession) }
    store.supervisorOpenDecisions = decisions
    self.store = store
    history = GlobalWindowNavigationHistory(store: store, initialDashboardRoute: .agents)
    let suiteName = "HarnessMonitorPreview.DashboardAgents.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    let resolvedSelection =
      selectionRawValue
      ?? selectedIdentity?.selectionRawValue
      ?? state.agents.first?.identity.selectionRawValue
      ?? ""
    defaults.set(resolvedSelection, forKey: DashboardAgentSelectionDefaults.storageKey)
    selectionDefaults = defaults
  }

  var body: some View {
    DashboardAgentsRouteView(
      store: store,
      sessions: [PreviewFixtures.summary],
      history: history,
      isRouteVisible: true,
      refreshesAutomatically: false,
      initialState: state,
      initialTerminalDetail: initialTerminalDetail,
      initialAcpDetail: initialAcpDetail,
      initialCodexDetail: initialCodexDetail,
      selectionDefaults: selectionDefaults
    )
  }
}
