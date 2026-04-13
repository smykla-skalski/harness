import Foundation
import Testing

@testable import HarnessMonitorKit

private actor InspectorActionTestBarrier {
  private var entered = false
  private var enteredContinuation: CheckedContinuation<Void, Never>?
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func enterAndWait() async {
    entered = true
    enteredContinuation?.resume()
    enteredContinuation = nil
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilEntered() async {
    guard !entered else { return }
    await withCheckedContinuation { continuation in
      enteredContinuation = continuation
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

@MainActor
@Suite("Store action scope (inFlightActionID)")
struct HarnessMonitorStoreActionScopeTests {
  @Test("inFlightActionID is nil at rest")
  func inFlightActionIDStartsNil() async {
    let store = await makeBootstrappedStore()
    #expect(store.inFlightActionID == nil)
  }

  @Test("mutateSelectedSession sets inFlightActionID during the mutation and clears it after")
  func mutateSelectedSessionSetsAndClearsActionID() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    let sessionID = PreviewFixtures.summary.sessionId
    await store.selectSession(sessionID)

    let expectedKey = InspectorActionID.createTask(sessionID: sessionID).key
    #expect(store.inFlightActionID == nil)

    let barrier = InspectorActionTestBarrier()
    async let mutationResult: Bool = store.mutateSelectedSession(
      actionName: "Create task",
      actionID: expectedKey,
      using: client,
      sessionID: sessionID,
      mutation: {
        await barrier.enterAndWait()
        return PreviewFixtures.detail
      }
    )

    await barrier.waitUntilEntered()
    #expect(store.inFlightActionID == expectedKey)

    await barrier.release()
    _ = await mutationResult
    #expect(store.inFlightActionID == nil)
  }

  @Test("mutateSelectedSession clears inFlightActionID after mutation throws")
  func mutateSelectedSessionClearsOnThrow() async {
    let client = FailingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    let sessionID = PreviewFixtures.summary.sessionId
    await store.selectSession(sessionID)

    let expectedKey = InspectorActionID.createTask(sessionID: sessionID).key
    _ = await store.createTask(
      title: "Irrelevant failure",
      context: nil,
      severity: .medium,
      actor: "leader-claude"
    )

    #expect(store.inFlightActionID == nil)
    #expect(expectedKey == InspectorActionID.createTask(sessionID: sessionID).key)
  }

  @Test("Switching to a different session clears inFlightActionID")
  func sessionSwitchClearsInFlightActionID() async {
    let store = await makeBootstrappedStore()
    let firstSession = PreviewFixtures.summary.sessionId
    await store.selectSession(firstSession)

    let key = InspectorActionID.createTask(sessionID: firstSession).key
    store.inFlightActionID = key
    #expect(store.inFlightActionID == key)

    store.primeSessionSelection(nil)
    #expect(store.inFlightActionID == nil)
  }

  @Test("Re-priming the same session does not clear inFlightActionID")
  func samSessionPrimeKeepsInFlightActionID() async {
    let store = await makeBootstrappedStore()
    let sessionID = PreviewFixtures.summary.sessionId
    await store.selectSession(sessionID)

    let key = InspectorActionID.createTask(sessionID: sessionID).key
    store.inFlightActionID = key

    store.primeSessionSelection(sessionID)
    #expect(store.inFlightActionID == key)
  }

  @Test("Concurrent mutateSelectedSession serialize via inFlightActionID")
  func concurrentMutateSelectedSessionSerializes() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    let sessionID = PreviewFixtures.summary.sessionId
    await store.selectSession(sessionID)

    let key1 = InspectorActionID.createTask(sessionID: sessionID).key
    let key2 = InspectorActionID.assignTask(sessionID: sessionID, taskID: "t1").key

    async let r1: Bool = store.mutateSelectedSession(
      actionName: "Create task",
      actionID: key1,
      using: client,
      sessionID: sessionID,
      mutation: {
        try await Task.sleep(for: .milliseconds(20))
        return PreviewFixtures.detail
      }
    )
    async let r2: Bool = store.mutateSelectedSession(
      actionName: "Assign task",
      actionID: key2,
      using: client,
      sessionID: sessionID,
      mutation: {
        try await Task.sleep(for: .milliseconds(10))
        return PreviewFixtures.detail
      }
    )
    _ = await (r1, r2)
    #expect(store.inFlightActionID == nil)
  }

  @Test("Mutating inFlightActionID does not invalidate timeline observers")
  func mutatingInFlightDoesNotInvalidateTimeline() async {
    let store = await makeBootstrappedStore()
    let invalidations = await invalidationCount(
      { store.timeline.count },
      after: {
        await MainActor.run {
          store.inFlightActionID = "sess-1/createTask"
        }
      }
    )
    #expect(invalidations == 0)
  }

  @Test("Mutating inFlightActionID does not invalidate observers of unrelated slices")
  func mutatingInFlightDoesNotInvalidateUnrelated() async {
    let store = await makeBootstrappedStore()
    store.inFlightActionID = nil

    let invalidations = await invalidationCount(
      { store.toast.activeFeedback.count },
      after: {
        await MainActor.run {
          store.inFlightActionID = "foo"
        }
      }
    )

    #expect(invalidations == 0)
  }
}
