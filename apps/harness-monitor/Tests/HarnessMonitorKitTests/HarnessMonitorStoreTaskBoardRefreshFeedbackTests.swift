import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor task-board refresh feedback")
struct HarnessMonitorStoreTaskBoardRefreshFeedbackTests {
  @Test("Refresh reports staged progress and completes at the bottom right")
  func refreshReportsStagedProgressAndCompletesAtBottomRight() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    var toastEvents: [ToastHistoryEvent] = []
    store.toast.onHistoryEvent = { toastEvents.append($0) }

    await store.refreshTaskBoardDashboard()

    let progressMessages = toastEvents.compactMap { event -> String? in
      guard event.feedback.severity == .activity else { return nil }
      switch event.kind {
      case .presented, .refreshed:
        return event.feedback.message
      case .dismissed:
        return nil
      }
    }
    #expect(progressMessages == ["Syncing task sources", "Loading refreshed tasks"])
    #expect(store.toast.activeFeedback.count == 1)
    #expect(store.toast.activeFeedback.first?.message == "Task board refreshed")
    #expect(store.toast.activeFeedback.first?.severity == .success)
    #expect(store.toast.activeFeedback.first?.position == .bottomTrailing)
  }
}
