import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("SessionWindowSnapshotRefreshTrigger")
struct SessionWindowSnapshotRefreshTriggerTests {
  @Test("same inputs keep the trigger stable")
  func sameInputsKeepTriggerStable() {
    let baseline = SessionWindowSnapshotRefreshTrigger(
      sessionID: "sess-1",
      connectionState: .online,
      summaryUpdatedAt: "2026-05-09T12:00:00Z"
    )

    let candidate = SessionWindowSnapshotRefreshTrigger(
      sessionID: "sess-1",
      connectionState: .online,
      summaryUpdatedAt: "2026-05-09T12:00:00Z"
    )

    #expect(candidate == baseline)
  }

  @Test("connection changes invalidate the trigger")
  func connectionChangesInvalidateTrigger() {
    let baseline = SessionWindowSnapshotRefreshTrigger(
      sessionID: "sess-1",
      connectionState: .connecting,
      summaryUpdatedAt: "2026-05-09T12:00:00Z"
    )

    let candidate = SessionWindowSnapshotRefreshTrigger(
      sessionID: "sess-1",
      connectionState: .online,
      summaryUpdatedAt: "2026-05-09T12:00:00Z"
    )

    #expect(candidate != baseline)
  }

  @Test("persisted snapshot writes do not invalidate the trigger")
  func persistedSnapshotWritesDoNotInvalidateTrigger() {
    let baseline = SessionWindowSnapshotRefreshTrigger(
      sessionID: "sess-1",
      connectionState: .online,
      summaryUpdatedAt: "2026-05-09T12:00:00Z"
    )

    let candidate = SessionWindowSnapshotRefreshTrigger(
      sessionID: "sess-1",
      connectionState: .online,
      summaryUpdatedAt: "2026-05-09T12:00:00Z"
    )

    #expect(candidate == baseline)
  }

  @Test("catalog summary updates invalidate the trigger")
  func catalogSummaryUpdatesInvalidateTrigger() {
    let baseline = SessionWindowSnapshotRefreshTrigger(
      sessionID: "sess-1",
      connectionState: .online,
      summaryUpdatedAt: "2026-05-09T12:00:00Z"
    )

    let candidate = SessionWindowSnapshotRefreshTrigger(
      sessionID: "sess-1",
      connectionState: .online,
      summaryUpdatedAt: "2026-05-09T12:05:00Z"
    )

    #expect(candidate != baseline)
  }
}
