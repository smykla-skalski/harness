import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Toast slice positions")
struct ToastSlicePositionTests {
  @Test("Toast position defaults top trailing and can target bottom trailing")
  func toastPositionDefaultsAndCanTargetBottomTrailing() async {
    let slice = ToastSlice(clock: ManualClock())
    _ = slice.presentSuccess("top")
    _ = slice.presentFailure("bottom", position: .bottomTrailing)

    #expect(slice.activeFeedback(in: .topTrailing).map(\.message) == ["top"])
    #expect(slice.activeFeedback(in: .bottomTrailing).map(\.message) == ["bottom"])
  }

  @Test("Max visible is enforced per toast position")
  func maxVisibleIsEnforcedPerPosition() async {
    let clock = ManualClock()
    let slice = ToastSlice(clock: clock)
    _ = slice.presentSuccess("top")
    clock.advance(by: .seconds(3))
    _ = slice.presentSuccess("bottom one", position: .bottomTrailing)
    clock.advance(by: .seconds(3))
    _ = slice.presentSuccess("bottom two", position: .bottomTrailing)
    clock.advance(by: .seconds(3))
    _ = slice.presentSuccess("bottom three", position: .bottomTrailing)
    clock.advance(by: .seconds(3))
    _ = slice.presentSuccess("bottom four", position: .bottomTrailing)

    #expect(slice.activeFeedback(in: .topTrailing).map(\.message) == ["top"])
    #expect(
      slice.activeFeedback(in: .bottomTrailing).map(\.message)
        == ["bottom four", "bottom three", "bottom two"]
    )
  }

  @Test("Identical messages in different positions are not deduped together")
  func dedupeDoesNotCrossPositions() async {
    let clock = ManualClock()
    let slice = ToastSlice(clock: clock)
    _ = slice.presentFailure("Daemon error 404")
    clock.advance(by: .seconds(1))
    _ = slice.presentFailure("Daemon error 404", position: .bottomTrailing)

    #expect(slice.activeFeedback.count == 2)
    #expect(slice.activeFeedback(in: .topTrailing).count == 1)
    #expect(slice.activeFeedback(in: .bottomTrailing).count == 1)
  }
}
