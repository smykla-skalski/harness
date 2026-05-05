import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite struct AcpRuntimeStatusEdgeAccentTests {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  @Test func firedWatchdogClassifiesAsFired() {
    #expect(
      AcpRuntimeStatusEdgeAccent.classify(
        watchdogDisplayState: "fired",
        pendingPermissions: 0,
        promptDeadline: nil,
        now: now
      ) == .fired
    )
  }

  @Test func expiredWatchdogClassifiesAsFired() {
    #expect(
      AcpRuntimeStatusEdgeAccent.classify(
        watchdogDisplayState: "EXPIRED",
        pendingPermissions: 0,
        promptDeadline: nil,
        now: now
      ) == .fired
    )
  }

  @Test func stallingWatchdogClassifiesAsStalling() {
    #expect(
      AcpRuntimeStatusEdgeAccent.classify(
        watchdogDisplayState: "  Stalling  ",
        pendingPermissions: 0,
        promptDeadline: nil,
        now: now
      ) == .stalling
    )
  }

  @Test func warningWatchdogClassifiesAsStalling() {
    #expect(
      AcpRuntimeStatusEdgeAccent.classify(
        watchdogDisplayState: "warning",
        pendingPermissions: 0,
        promptDeadline: nil,
        now: now
      ) == .stalling
    )
  }

  @Test func pendingPermissionPicksAwaitingPermission() {
    #expect(
      AcpRuntimeStatusEdgeAccent.classify(
        watchdogDisplayState: "active",
        pendingPermissions: 1,
        promptDeadline: nil,
        now: now
      ) == .awaitingPermission
    )
  }

  @Test func deadlineWithin30sPicksDeadlineApproaching() {
    let deadline = now.addingTimeInterval(15)
    #expect(
      AcpRuntimeStatusEdgeAccent.classify(
        watchdogDisplayState: "active",
        pendingPermissions: 0,
        promptDeadline: deadline,
        now: now
      ) == .deadlineApproaching
    )
  }

  @Test func deadlineBeyond30sIsClear() {
    let deadline = now.addingTimeInterval(60)
    #expect(
      AcpRuntimeStatusEdgeAccent.classify(
        watchdogDisplayState: "active",
        pendingPermissions: 0,
        promptDeadline: deadline,
        now: now
      ) == nil
    )
  }

  @Test func expiredDeadlineDoesNotTrigger() {
    let deadline = now.addingTimeInterval(-5)
    #expect(
      AcpRuntimeStatusEdgeAccent.classify(
        watchdogDisplayState: "active",
        pendingPermissions: 0,
        promptDeadline: deadline,
        now: now
      ) == nil
    )
  }

  @Test func firedBeatsPendingPermissions() {
    #expect(
      AcpRuntimeStatusEdgeAccent.classify(
        watchdogDisplayState: "fired",
        pendingPermissions: 3,
        promptDeadline: nil,
        now: now
      ) == .fired
    )
  }

  @Test func stallingBeatsPendingPermissions() {
    #expect(
      AcpRuntimeStatusEdgeAccent.classify(
        watchdogDisplayState: "stalling",
        pendingPermissions: 3,
        promptDeadline: nil,
        now: now
      ) == .stalling
    )
  }

  @Test func calmStateClassifiesAsNil() {
    #expect(
      AcpRuntimeStatusEdgeAccent.classify(
        watchdogDisplayState: "active",
        pendingPermissions: 0,
        promptDeadline: nil,
        now: now
      ) == nil
    )
  }

  @Test func tintNoneReturnsNil() {
    #expect(AcpRuntimeStatusEdgeAccent.tint(for: nil) == nil)
  }

  @Test func tintFiredReturnsDanger() {
    #expect(AcpRuntimeStatusEdgeAccent.tint(for: .fired) == HarnessMonitorTheme.danger)
  }

  @Test func tintStallingReturnsCaution() {
    #expect(AcpRuntimeStatusEdgeAccent.tint(for: .stalling) == HarnessMonitorTheme.caution)
  }

  @Test func tintAwaitingPermissionReturnsCaution() {
    #expect(
      AcpRuntimeStatusEdgeAccent.tint(for: .awaitingPermission) == HarnessMonitorTheme.caution
    )
  }

  @Test func tintDeadlineApproachingReturnsCaution() {
    #expect(
      AcpRuntimeStatusEdgeAccent.tint(for: .deadlineApproaching) == HarnessMonitorTheme.caution
    )
  }
}
