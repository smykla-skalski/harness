import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Agents window ACP session context")
@MainActor
struct AgentsWindowAcpSessionContextTests {
  @Test("Create selection retains last session context and reseats selected session when missing")
  func createSelectionRestoresMissingSelectedSession() async {
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [PreviewFixtures.summary],
      detailsByID: [PreviewFixtures.summary.sessionId: PreviewFixtures.detail],
      detail: PreviewFixtures.detail
    )
    let store = await makeBootstrappedStore(client: client)
    let sessionID = PreviewFixtures.summary.sessionId
    store.selectedSessionID = nil

    let view = AgentsWindowView(store: store)
    await view.handleSelectionChange(
      from: .decisions(sessionID: sessionID),
      to: .create
    )

    #expect(view.viewModel.createSessionID == sessionID)
    #expect(store.selectedSessionID == sessionID)
  }

  @Test("ACP start from create uses anchored session instead of no-selection guard")
  func acpStartFromCreateUsesAnchoredSession() async {
    let store = await makeBootstrappedStore(client: RecordingHarnessClient())
    let view = AgentsWindowView(store: store)
    store.toast.dismissAll()
    store.selectedSessionID = nil
    view.viewModel.selection = .create
    view.viewModel.createSessionID = PreviewFixtures.summary.sessionId
    view.viewModel.selectedLaunchSelection = .acp("copilot")

    let didHandleAcp = await view.startAcpAgentIfSelected()

    #expect(didHandleAcp)
    #expect(store.currentFailureFeedbackMessage != store.selectedSessionActionUnavailableMessage)
    #expect(store.currentFailureFeedbackMessage?.contains("No session is selected") == false)
  }
}
