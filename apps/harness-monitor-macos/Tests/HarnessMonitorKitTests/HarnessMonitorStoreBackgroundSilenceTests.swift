import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Background daemon errors do not surface as user feedback")
struct HarnessMonitorStoreBackgroundSilenceTests {
  @Test("Stream reconnect attempt does not push a feedback toast")
  func streamReconnectAttemptIsSilent() async {
    let store = await makeBootstrappedStore()
    store.toast.dismissAll()

    let error = HarnessMonitorAPIError.server(code: 502, message: "bad gateway")
    store.recordReconnectAttempt(
      scope: "global stream",
      nextAttempt: 1,
      error: error
    )

    #expect(store.toast.activeFeedback.isEmpty)
    #expect(store.currentFailureFeedbackMessage == nil)
  }

  @Test("Push fallback timeline failure does not push a feedback toast")
  func pushFallbackTimelineFailureIsSilent() async {
    let client = RecordingHarnessClient()
    client.configureTimelineError(
      HarnessMonitorAPIError.server(code: 503, message: "timeline-unavailable"),
      for: PreviewFixtures.summary.sessionId
    )
    let store = await makeBootstrappedStore(client: client)
    store.toast.dismissAll()

    await store.performPushFallbackTimelineRefresh(
      using: client,
      sessionID: PreviewFixtures.summary.sessionId
    )

    #expect(store.toast.activeFeedback.isEmpty)
    #expect(store.currentFailureFeedbackMessage == nil)
  }

  @Test("Session hydration failure does not push a feedback toast")
  func sessionHydrationFailureIsSilent() async {
    let client = RecordingHarnessClient()
    let unknownSessionID = "session-that-does-not-exist"
    client.configureSessionDetailError(
      HarnessMonitorAPIError.server(code: 404, message: "session-missing"),
      for: unknownSessionID
    )
    let store = await makeBootstrappedStore(client: client)
    store.toast.dismissAll()

    await store.selectSession(unknownSessionID)

    #expect(store.toast.activeFeedback.isEmpty)
    #expect(store.currentFailureFeedbackMessage == nil)
  }
}
