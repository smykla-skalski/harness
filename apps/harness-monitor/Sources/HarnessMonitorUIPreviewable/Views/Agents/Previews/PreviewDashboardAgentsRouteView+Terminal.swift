import AppKit
import HarnessMonitorKit
import SwiftUI

extension DashboardAgentsPreviewRenderer {
  @MainActor
  static func renderTerminalStates(
    defaultIndex: Int,
    largestIndex: Int,
    directory: String
  ) -> Bool {
    render(
      name: "agents-terminal-management",
      state: DashboardAgentsPreviewFixtures.liveState,
      textSizeIndex: defaultIndex,
      directory: directory,
      selectedIdentity: DashboardAgentsPreviewFixtures.terminalAgent.identity,
      initialTerminalDetail: DashboardAgentsPreviewFixtures.managedTerminalDetail
    )
      && render(
        name: "agents-terminal-largest-text",
        state: DashboardAgentsPreviewFixtures.liveState,
        textSizeIndex: largestIndex,
        directory: directory,
        selectedIdentity: DashboardAgentsPreviewFixtures.terminalAgent.identity,
        initialTerminalDetail: DashboardAgentsPreviewFixtures.managedTerminalDetail
      )
      && renderTerminalNarrowLargestText(
        textSizeIndex: largestIndex,
        directory: directory
      )
      && renderTerminalOutputAndInput(
        textSizeIndex: defaultIndex,
        directory: directory
      )
      && render(
        name: "agents-terminal-unavailable",
        state: DashboardAgentsPreviewFixtures.liveState,
        textSizeIndex: defaultIndex,
        directory: directory,
        selectedIdentity: DashboardAgentsPreviewFixtures.terminalAgent.identity,
        initialTerminalDetail: DashboardAgentsPreviewFixtures.unavailableTerminalDetail
      )
      && render(
        name: "agents-terminal-stopped",
        state: DashboardAgentsPreviewFixtures.stoppedTerminalState,
        textSizeIndex: defaultIndex,
        directory: directory,
        selectedIdentity: DashboardAgentsPreviewFixtures.stoppedTerminalAgent.identity,
        initialTerminalDetail: DashboardAgentsPreviewFixtures.stoppedTerminalDetail
      )
      && render(
        name: "agents-terminal-failed",
        state: DashboardAgentsPreviewFixtures.failedTerminalState,
        textSizeIndex: defaultIndex,
        directory: directory,
        selectedIdentity: DashboardAgentsPreviewFixtures.failedTerminalAgent.identity,
        initialTerminalDetail: DashboardAgentsPreviewFixtures.failedTerminalDetail
      )
      && renderTerminalCreateSheet(textSizeIndex: defaultIndex, directory: directory)
  }

  @MainActor
  private static func renderTerminalOutputAndInput(
    textSizeIndex: Int,
    directory: String
  ) -> Bool {
    let detail = DashboardAgentsPreviewFixtures.managedTerminalDetail
    guard let snapshot = detail.snapshot else { return false }
    let state = DashboardTerminalAgentDetailState(
      detail: detail,
      agentID: DashboardAgentsPreviewFixtures.terminalAgent.managedAgentID
    )
    return renderSheet(
      name: "agents-terminal-output-input",
      textSizeIndex: textSizeIndex,
      directory: directory
    ) {
      VStack(alignment: .leading, spacing: 20) {
        DashboardAcpSection(title: "Terminal output") {
          DashboardTerminalViewport(snapshot: snapshot, onResize: { _ in true })
        }
        DashboardTerminalComposer(
          state: state,
          isTerminalActive: true,
          onSend: {},
          onControl: { _ in }
        )
      }
      .padding(24)
      .frame(width: 760, height: 660, alignment: .topLeading)
    }
  }

  @MainActor
  private static func renderTerminalNarrowLargestText(
    textSizeIndex: Int,
    directory: String
  ) -> Bool {
    let detail = DashboardAgentsPreviewFixtures.managedTerminalDetail
    return renderSheet(
      name: "agents-terminal-narrow-largest-text",
      textSizeIndex: textSizeIndex,
      directory: directory
    ) {
      DashboardTerminalAgentDetailView(
        store: HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded),
        agent: DashboardAgentsPreviewFixtures.terminalAgent,
        state: DashboardTerminalAgentDetailState(
          detail: detail,
          agentID: DashboardAgentsPreviewFixtures.terminalAgent.managedAgentID
        ),
        loadsAutomatically: false,
        onMembershipRemoved: {}
      )
      .frame(width: 380, height: 660)
    }
  }

  @MainActor
  private static func renderTerminalCreateSheet(
    textSizeIndex: Int,
    directory: String
  ) -> Bool {
    renderSheet(
      name: "agents-terminal-create",
      textSizeIndex: textSizeIndex,
      directory: directory
    ) {
      DashboardTerminalAgentCreateSheet(
        store: HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded),
        sessions: [PreviewFixtures.summary],
        onCreated: { _, _ in }
      )
      .frame(width: 680, height: 600)
    }
  }
}
