import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Store feedback forwarding")
struct HarnessMonitorStoreFeedbackForwardTests {
  @Test("Successful daemon action presents a success toast and clears the legacy slot")
  func successfulDaemonActionPresentsSuccessToast() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)
    store.toast.dismissAll()

    await store.createTask(
      title: "Forwarder smoke test",
      context: nil,
      severity: .medium,
      actor: "leader-claude"
    )

    #expect(store.toast.activeFeedback.first?.message == "Create task")
    #expect(store.toast.activeFeedback.first?.severity == .success)
  }

  @Test("Daemon action failure presents a failure toast")
  func daemonActionFailurePresentsFailureToast() async {
    let store = await makeBootstrappedStore()
    store.toast.dismissAll()

    await store.refreshDaemonStatus()
    let synthetic = "Synthetic action failure"
    store.presentFailureFeedback(synthetic)

    #expect(store.toast.activeFeedback.first?.message == synthetic)
    #expect(store.toast.activeFeedback.first?.severity == .failure)
  }

  @Test("Mutating the toast slice does not invalidate observers of unrelated store slices")
  func mutatingToastDoesNotInvalidateUnrelatedSlices() async {
    let store = await makeBootstrappedStore()
    store.toast.dismissAll()

    let invalidations = await invalidationCount(
      { store.selectedSessionID },
      after: {
        _ = await MainActor.run {
          store.toast.presentSuccess("isolated mutation")
        }
      }
    )

    #expect(invalidations == 0)
  }
}
