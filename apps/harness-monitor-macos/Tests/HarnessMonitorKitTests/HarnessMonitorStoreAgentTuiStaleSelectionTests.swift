import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor stale terminal agent recovery")
struct HarnessMonitorStoreAgentTuiStaleSelectionTests {
  @Test("Stale managed-agent input errors clear the dead selection without a failure toast")
  func staleManagedAgentInputErrorClearsDeadSelectionSilently() async {
    let client = RecordingHarnessClient()
    let running = client.agentTuiFixture()
    client.configureAgentTuis([running], for: PreviewFixtures.summary.sessionId)
    client.configureAgentTuiInputError(staleManagedAgentError(), for: running.tuiId)
    let store = await selectedStore(client: client)
    store.selectAgentTui(tuiID: running.tuiId)

    let sent = await store.sendAgentTuiInput(tuiID: running.tuiId, input: .text("status"))

    #expect(sent == false)
    #expect(store.selectedAgentTui == nil)
    #expect(store.selectedAgentTuis.isEmpty)
    #expect(store.currentFailureFeedbackMessage == nil)
  }

  @Test("Stale managed-agent refresh clears the dead selection without a failure toast")
  func staleManagedAgentRefreshClearsDeadSelectionSilently() async {
    let client = RecordingHarnessClient()
    let running = client.agentTuiFixture()
    client.configureAgentTuis([running], for: PreviewFixtures.summary.sessionId)
    client.configureAgentTuiReadError(staleManagedAgentError(), for: running.tuiId)
    let store = await selectedStore(client: client)
    store.selectAgentTui(tuiID: running.tuiId)

    let refreshed = await store.refreshSelectedAgentTui()

    #expect(refreshed == false)
    #expect(store.selectedAgentTui == nil)
    #expect(store.selectedAgentTuis.isEmpty)
    #expect(store.currentFailureFeedbackMessage == nil)
  }

  @Test("Stale managed-agent resize errors clear the dead selection without a failure toast")
  func staleManagedAgentResizeErrorClearsDeadSelectionSilently() async {
    let client = RecordingHarnessClient()
    let running = client.agentTuiFixture(rows: 32, cols: 120)
    client.configureAgentTuis([running], for: PreviewFixtures.summary.sessionId)
    client.configureAgentTuiResizeError(staleManagedAgentError(), for: running.tuiId)
    let store = await selectedStore(client: client)
    store.selectAgentTui(tuiID: running.tuiId)

    let resized = await store.resizeAgentTui(tuiID: running.tuiId, rows: 48, cols: 132)

    #expect(resized == false)
    #expect(store.selectedAgentTui == nil)
    #expect(store.selectedAgentTuis.isEmpty)
    #expect(store.currentFailureFeedbackMessage == nil)
  }

  @Test("Stale managed-agent stop errors clear the dead selection without a failure toast")
  func staleManagedAgentStopErrorClearsDeadSelectionSilently() async {
    let client = RecordingHarnessClient()
    let running = client.agentTuiFixture()
    client.configureAgentTuis([running], for: PreviewFixtures.summary.sessionId)
    client.configureAgentTuiStopError(staleManagedAgentError(), for: running.tuiId)
    let store = await selectedStore(client: client)
    store.selectAgentTui(tuiID: running.tuiId)

    let stopped = await store.stopAgentTui(tuiID: running.tuiId)

    #expect(stopped == false)
    #expect(store.selectedAgentTui == nil)
    #expect(store.selectedAgentTuis.isEmpty)
    #expect(store.currentFailureFeedbackMessage == nil)
  }

  private func staleManagedAgentError() -> HarnessMonitorAPIError {
    let message =
      #"{"error":{"code":"KSRCLI090","message":"session not active: "#
      + #"managed agent 'agent-tui-1' not found","details":null}}"#
    return HarnessMonitorAPIError.server(
      code: 400,
      message: message
    )
  }
}
