import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Toast slice")
struct ToastSliceTests {
  @Test("Present success appends a feedback entry at index 0")
  func presentSuccessAppendsAtIndexZero() async {
    let slice = ToastSlice(clock: ManualClock())
    let id = slice.presentSuccess("Created task")

    #expect(slice.activeFeedback.count == 1)
    #expect(slice.activeFeedback.first?.id == id)
    #expect(slice.activeFeedback.first?.message == "Created task")
    #expect(slice.activeFeedback.first?.severity == .success)
  }

  @Test("Present failure appends a feedback entry at index 0")
  func presentFailureAppendsAtIndexZero() async {
    let slice = ToastSlice(clock: ManualClock())
    let id = slice.presentFailure("Daemon refused")

    #expect(slice.activeFeedback.count == 1)
    #expect(slice.activeFeedback.first?.id == id)
    #expect(slice.activeFeedback.first?.severity == .failure)
  }

  @Test("Multiple presents stack newest first")
  func multiplePresentsStackNewestFirst() async {
    let clock = ManualClock()
    let slice = ToastSlice(clock: clock)
    _ = slice.presentSuccess("first")
    clock.advance(by: .seconds(3))
    _ = slice.presentSuccess("second")
    clock.advance(by: .seconds(3))
    _ = slice.presentSuccess("third")

    #expect(slice.activeFeedback.map(\.message) == ["third", "second", "first"])
  }

  @Test("Max visible default is 3 and oldest entry is evicted on overflow")
  func maxVisibleEvictsOldest() async {
    let clock = ManualClock()
    let slice = ToastSlice(clock: clock)
    _ = slice.presentSuccess("one")
    clock.advance(by: .seconds(3))
    _ = slice.presentSuccess("two")
    clock.advance(by: .seconds(3))
    _ = slice.presentSuccess("three")
    clock.advance(by: .seconds(3))
    _ = slice.presentSuccess("four")

    #expect(slice.activeFeedback.count == 3)
    #expect(slice.activeFeedback.map(\.message) == ["four", "three", "two"])
  }

  @Test("Identical message+severity within dedupe window refreshes existing entry")
  func dedupeWithinWindowRefreshesExisting() async {
    let clock = ManualClock()
    let slice = ToastSlice(clock: clock)
    let firstID = slice.presentFailure("Daemon error 404")
    let originalIssuedAt = slice.activeFeedback.first?.issuedAt
    clock.advance(by: .seconds(1))
    let secondID = slice.presentFailure("Daemon error 404")

    #expect(slice.activeFeedback.count == 1)
    #expect(firstID == secondID)
    #expect(slice.activeFeedback.first?.issuedAt != originalIssuedAt)
  }

  @Test("Same message different severity is not deduped")
  func differentSeverityNotDeduped() async {
    let clock = ManualClock()
    let slice = ToastSlice(clock: clock)
    _ = slice.presentSuccess("ambiguous")
    clock.advance(by: .seconds(1))
    _ = slice.presentFailure("ambiguous")

    #expect(slice.activeFeedback.count == 2)
  }

  @Test("Identical message after dedupe window pushes a new entry")
  func dedupeWindowExpires() async {
    let clock = ManualClock()
    let slice = ToastSlice(clock: clock)
    _ = slice.presentSuccess("repeating")
    clock.advance(by: .seconds(3))
    _ = slice.presentSuccess("repeating")

    #expect(slice.activeFeedback.count == 2)
  }

  @Test("Auto-dismiss success after success delay")
  func autoDismissSuccess() async {
    let clock = ManualClock()
    let slice = ToastSlice(clock: clock)
    slice.successDismissDelay = .seconds(4)
    _ = slice.presentSuccess("hello")

    clock.advance(by: .seconds(4))
    await slice.flushPendingDismissals()

    #expect(slice.activeFeedback.isEmpty)
  }

  @Test("Auto-dismiss failure after failure delay")
  func autoDismissFailure() async {
    let clock = ManualClock()
    let slice = ToastSlice(clock: clock)
    slice.failureDismissDelay = .seconds(8)
    _ = slice.presentFailure("oops")

    clock.advance(by: .seconds(4))
    await slice.flushPendingDismissals()
    #expect(slice.activeFeedback.count == 1)

    clock.advance(by: .seconds(4))
    await slice.flushPendingDismissals()
    #expect(slice.activeFeedback.isEmpty)
  }

  @Test("Manual dismiss removes the entry and cancels its timer")
  func manualDismissRemovesEntry() async {
    let clock = ManualClock()
    let slice = ToastSlice(clock: clock)
    let id = slice.presentSuccess("manual")
    slice.dismiss(id: id)

    #expect(slice.activeFeedback.isEmpty)
    #expect(slice.pendingDismissCount == 0)
  }

  @Test("Dismiss all clears the array and cancels every timer")
  func dismissAllClearsAndCancels() async {
    let clock = ManualClock()
    let slice = ToastSlice(clock: clock)
    _ = slice.presentSuccess("a")
    clock.advance(by: .seconds(3))
    _ = slice.presentSuccess("b")
    slice.dismissAll()

    #expect(slice.activeFeedback.isEmpty)
    #expect(slice.pendingDismissCount == 0)
  }

  @Test("Pause records remaining time and cancels live tasks")
  func pauseRecordsRemainingAndCancels() async {
    let clock = ManualClock()
    let slice = ToastSlice(clock: clock)
    slice.successDismissDelay = .seconds(4)
    _ = slice.presentSuccess("paused")
    clock.advance(by: .seconds(1))

    slice.pauseTimers()
    await slice.flushPendingDismissals()

    #expect(slice.activeFeedback.first?.pausedRemaining == .seconds(3))
    #expect(slice.pendingDismissCount == 0)
  }

  @Test("Resume after pause re-arms timers using paused remaining duration")
  func resumeUsesPausedRemaining() async {
    let clock = ManualClock()
    let slice = ToastSlice(clock: clock)
    slice.successDismissDelay = .seconds(4)
    _ = slice.presentSuccess("paused")
    clock.advance(by: .seconds(1))
    slice.pauseTimers()

    slice.resumeTimers()
    #expect(slice.activeFeedback.first?.pausedRemaining == nil)

    clock.advance(by: .seconds(3))
    await slice.flushPendingDismissals()

    #expect(slice.activeFeedback.isEmpty)
  }

  @Test("Resume re-arming does not dismiss before paused remaining elapses")
  func resumeRespectsPausedRemaining() async {
    let clock = ManualClock()
    let slice = ToastSlice(clock: clock)
    slice.successDismissDelay = .seconds(4)
    _ = slice.presentSuccess("paused")
    clock.advance(by: .seconds(1))
    slice.pauseTimers()
    slice.resumeTimers()

    clock.advance(by: .seconds(2))
    await slice.flushPendingDismissals()

    #expect(slice.activeFeedback.count == 1)
  }

  @Test("Each toast has a unique UUID even for identical messages outside the dedupe window")
  func uniqueUUIDsOutsideDedupeWindow() async {
    let clock = ManualClock()
    let slice = ToastSlice(clock: clock)
    let firstID = slice.presentSuccess("repeat")
    clock.advance(by: .seconds(3))
    let secondID = slice.presentSuccess("repeat")

    #expect(firstID != secondID)
  }

  @Test("Pending dismiss count is zero after every toast is dismissed")
  func dismissTaskBookkeepingHasNoLeak() async {
    let clock = ManualClock()
    let slice = ToastSlice(clock: clock)
    slice.successDismissDelay = .seconds(2)
    _ = slice.presentSuccess("a")
    clock.advance(by: .seconds(3))
    _ = slice.presentSuccess("b")

    clock.advance(by: .seconds(2))
    await slice.flushPendingDismissals()

    #expect(slice.activeFeedback.isEmpty)
    #expect(slice.pendingDismissCount == 0)
  }

  @Test("Concurrent presents from detached tasks order deterministically by issuedAt")
  func concurrentPresentsAreOrderedByIssuedAt() async {
    let clock = ManualClock()
    let slice = ToastSlice(clock: clock)

    async let firstSlot: Void = MainActor.run {
      _ = slice.presentSuccess("alpha")
    }
    await firstSlot
    clock.advance(by: .seconds(3))

    async let secondSlot: Void = MainActor.run {
      _ = slice.presentSuccess("beta")
    }
    await secondSlot

    #expect(slice.activeFeedback.map(\.message) == ["beta", "alpha"])
  }

  @Test("Store exposes toast slice and forwards present success")
  func storePresentSuccessForwardsToSlice() async {
    let store = await makeBootstrappedStore()
    store.presentSuccessFeedback("forwarded")

    #expect(store.toast.activeFeedback.first?.message == "forwarded")
    #expect(store.toast.activeFeedback.first?.severity == .success)
  }

  @Test("Store forwards present failure")
  func storePresentFailureForwardsToSlice() async {
    let store = await makeBootstrappedStore()
    store.presentFailureFeedback("forwarded failure")

    #expect(store.toast.activeFeedback.first?.message == "forwarded failure")
    #expect(store.toast.activeFeedback.first?.severity == .failure)
  }

  @Test("Store dismiss feedback forwards to slice")
  func storeDismissFeedbackForwards() async {
    let store = await makeBootstrappedStore()
    let id = store.presentSuccessFeedback("temporary")
    store.dismissFeedback(id: id)

    #expect(store.toast.activeFeedback.isEmpty)
  }
}

// MARK: - Test helpers

@MainActor
final class ManualClock: ContinuousClockSource {
  private var current: ContinuousClock.Instant

  init() {
    self.current = ContinuousClock.now
  }

  var now: ContinuousClock.Instant {
    current
  }

  func advance(by duration: Duration) {
    current = current.advanced(by: duration)
  }
}
