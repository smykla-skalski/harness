import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor store signal actions")
struct HarnessMonitorStoreSignalTests {
  @Test("Send signal tracks the last action")
  func sendSignalTracksLastAction() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)

    await store.sendSignal(
      agentID: PreviewFixtures.agents[0].agentId,
      command: "inject_context",
      message: "Focus on the stalled review lane.",
      actionHint: "task:review"
    )

    #expect(
      client.recordedCalls()
        == [
          .sendSignal(
            sessionID: PreviewFixtures.summary.sessionId,
            agentID: PreviewFixtures.agents[0].agentId,
            command: "inject_context",
            actor: "leader-claude"
          )
        ]
    )
    #expect(store.selectedSession?.signals.count == PreviewFixtures.signals.count + 1)
    #expect(store.selectedSession?.signals.last?.agentId == PreviewFixtures.agents[0].agentId)
    #expect(store.selectedSession?.signals.last?.status == .pending)
    #expect(
      store.selectedSession?.signals.last?.signal.payload.message
        == "Focus on the stalled review lane."
    )
    #expect(
      store.selectedSession?.signals.last?.signal.payload.actionHint == "task:review"
    )
    #expect(store.currentSuccessFeedbackMessage == "Send signal")
  }

  @Test("Cancel signal forwards to daemon and records rejection")
  func cancelSignalForwardsToDaemon() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)

    await store.sendSignal(
      agentID: PreviewFixtures.agents[0].agentId,
      command: "inject_context",
      message: "Stalled review.",
      actionHint: nil
    )
    let pending = try? #require(store.selectedSession?.signals.last)
    let signalID = try? #require(pending?.signal.signalId)

    await store.cancelSignal(
      signalID: signalID ?? "",
      agentID: PreviewFixtures.agents[0].agentId
    )

    #expect(
      client.recordedCalls().contains(
        .cancelSignal(
          sessionID: PreviewFixtures.summary.sessionId,
          agentID: PreviewFixtures.agents[0].agentId,
          signalID: signalID ?? "",
          actor: "leader-claude"
        )
      )
    )
    #expect(store.currentSuccessFeedbackMessage == "Cancel signal")
    let cancelled = store.selectedSession?.signals.first { $0.signal.signalId == signalID }
    #expect(cancelled?.status == .rejected)
    #expect(cancelled?.acknowledgment?.result == .rejected)
  }

  @Test("Resend signal reuses sendSignal with the original payload")
  func resendSignalReusesSendSignal() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)

    await store.sendSignal(
      agentID: PreviewFixtures.agents[0].agentId,
      command: "inject_context",
      message: "Stalled review.",
      actionHint: "task:review"
    )
    let original = try? #require(store.selectedSession?.signals.last)

    guard let original else { return }
    await store.resendSignal(original)

    let sendCalls = client.recordedCalls().filter { call in
      if case .sendSignal = call { return true }
      return false
    }
    #expect(sendCalls.count == 2)
    #expect(store.currentSuccessFeedbackMessage == "Send signal")
  }

  private func selectedStore(client: RecordingHarnessClient) async -> HarnessMonitorStore {
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)
    return store
  }
}
