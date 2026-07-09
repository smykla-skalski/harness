import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Toast slice activity")
struct ToastSliceActivityTests {
  @Test("Activity toast updates by key and requires explicit dismissal")
  func activityToastUpdatesByKeyAndRequiresExplicitDismissal() async {
    let clock = ManualClock()
    let slice = ToastSlice(clock: clock)
    let firstID = slice.presentActivity(
      key: "pr-processing",
      message: "Processing PR URLs",
      position: .bottomTrailing
    )

    #expect(slice.activeFeedback.count == 1)
    #expect(slice.activeFeedback.first?.severity == .activity)
    #expect(slice.activeFeedback.first?.position == .bottomTrailing)
    #expect(slice.pendingDismissCount == 0)

    clock.advance(by: .seconds(60))
    await slice.flushPendingDismissals()

    #expect(slice.activeFeedback.count == 1)

    let otherID = slice.presentActivity(key: "other-progress", message: "Processing PR URLs")

    #expect(otherID != firstID)
    #expect(slice.activeFeedback.count == 2)
    #expect(slice.activeFeedback(in: .topTrailing).count == 1)
    #expect(slice.activeFeedback(in: .bottomTrailing).count == 1)

    slice.dismissActivity(key: "other-progress")

    let updatedID = slice.updateActivity(key: "pr-processing", message: "Loading PR details")

    #expect(updatedID == firstID)
    #expect(slice.activeFeedback.count == 1)
    #expect(slice.activeFeedback.first?.message == "Loading PR details")
    #expect(slice.activeFeedback.first?.position == .bottomTrailing)
    #expect(slice.pendingDismissCount == 0)

    slice.dismissActivity(key: "pr-processing")

    #expect(slice.activeFeedback.isEmpty)
  }
}
