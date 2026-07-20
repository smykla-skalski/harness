import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Task board lane hover tracking")
@MainActor
struct TaskBoardLaneHoverTrackingTests {
  private static let firstCard = TaskBoardLaneCardHoverID.api("card-1")
  private static let secondCard = TaskBoardLaneCardHoverID.api("card-2")

  /// Two cards stacked the way a lane lays them out: same width, 8pt gap.
  private func stackedLane() -> TaskBoardLaneHoverTracking {
    let tracking = TaskBoardLaneHoverTracking()
    tracking.setFrame(CGRect(x: 0, y: 0, width: 200, height: 60), for: Self.firstCard)
    tracking.setFrame(CGRect(x: 0, y: 68, width: 200, height: 60), for: Self.secondCard)
    return tracking
  }

  @Test("Resolves the card under the pointer")
  func resolvesCardUnderPointer() {
    let tracking = stackedLane()

    #expect(tracking.cardID(at: CGPoint(x: 100, y: 30)) == Self.firstCard)
    #expect(tracking.cardID(at: CGPoint(x: 100, y: 98)) == Self.secondCard)
  }

  @Test("Ignores the gap between cards and points past the last card")
  func ignoresPointsOutsideAnyCard() {
    let tracking = stackedLane()

    #expect(tracking.cardID(at: CGPoint(x: 100, y: 64)) == nil)
    #expect(tracking.cardID(at: CGPoint(x: 100, y: 400)) == nil)
  }

  /// Frames arrive per card now, so a card that goes away has to take its
  /// rect with it. A stale rect would keep winning hit tests at a position
  /// no card occupies any more.
  @Test("A removed card stops matching its old frame")
  func removedCardStopsMatching() {
    let tracking = stackedLane()

    tracking.removeFrame(for: Self.firstCard)

    #expect(tracking.cardID(at: CGPoint(x: 100, y: 30)) == nil)
    #expect(tracking.cardID(at: CGPoint(x: 100, y: 98)) == Self.secondCard)
  }

  @Test("Re-recording a frame moves the card's hit region")
  func reRecordingFrameMovesHitRegion() {
    let tracking = stackedLane()

    tracking.setFrame(CGRect(x: 0, y: 200, width: 200, height: 60), for: Self.firstCard)

    #expect(tracking.cardID(at: CGPoint(x: 100, y: 30)) == nil)
    #expect(tracking.cardID(at: CGPoint(x: 100, y: 230)) == Self.firstCard)
  }
}
