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

  @Test("Cancellation dismisses progress without reload or failure feedback")
  func cancellationDismissesProgressWithoutReloadOrFailureFeedback() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    let baselineItemReads = client.readCallCount(.taskBoardItems(nil))
    client.configureTaskBoardSyncError(CancellationError())

    await store.refreshTaskBoardDashboard()

    #expect(client.readCallCount(.taskBoardItems(nil)) == baselineItemReads)
    #expect(store.toast.activeFeedback.isEmpty)
    #expect(store.currentFailureFeedbackMessage == nil)
  }

  @Test("Refresh is ignored while another daemon action is in flight")
  func refreshIsIgnoredWhileAnotherDaemonActionIsInFlight() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.isDaemonActionInFlight = true
    defer { store.isDaemonActionInFlight = false }

    await store.refreshTaskBoardDashboard()

    #expect(
      !client.recordedCalls().contains(
        .syncTaskBoard(direction: .pull, dryRun: false, status: nil, provider: nil)
      )
    )
    #expect(store.toast.activeFeedback.isEmpty)
  }
}
