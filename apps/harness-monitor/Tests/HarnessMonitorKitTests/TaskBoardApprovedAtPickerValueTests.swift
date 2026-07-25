import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Task board approved-at picker value")
struct TaskBoardApprovedAtPickerValueTests {
  @Test("Parses an existing RFC3339 approval timestamp instead of the fallback")
  func parsesExistingApprovalTimestamp() {
    let fallback = Date(timeIntervalSince1970: 0)

    let date = TaskBoardApprovedAtPickerValue.date(
      fromApprovedAt: "2026-05-14T10:00:00Z",
      fallback: fallback
    )

    #expect(date == Date(timeIntervalSince1970: 1_778_752_800))
  }

  @Test("Falls back to the supplied default when there is no approval yet")
  func fallsBackWhenApprovedAtIsEmpty() {
    let fallback = Date(timeIntervalSince1970: 1_747_300_000)

    let date = TaskBoardApprovedAtPickerValue.date(fromApprovedAt: "", fallback: fallback)

    #expect(date == fallback)
  }

  @Test("Falls back instead of surfacing a timestamp the old free-text field let through malformed")
  func fallsBackOnUnparsableApprovedAt() {
    let fallback = Date(timeIntervalSince1970: 1_747_300_000)

    let date = TaskBoardApprovedAtPickerValue.date(
      fromApprovedAt: "not a real date",
      fallback: fallback
    )

    #expect(date == fallback)
  }

  @Test("Round-trips a picked date to an RFC3339 string the daemon accepts")
  func roundTripsPickedDateToRFC3339() {
    let picked = Date(timeIntervalSince1970: 1_778_759_461)

    let approvedAt = TaskBoardApprovedAtPickerValue.approvedAtString(from: picked)

    #expect(approvedAt == "2026-05-14T11:51:01Z")
    #expect(
      TaskBoardApprovedAtPickerValue.date(fromApprovedAt: approvedAt, fallback: .distantPast)
        == picked
    )
  }

  @Test("Sanitizing leaves an empty or valid approvedAt untouched")
  func sanitizingLeavesEmptyOrValidApprovedAtUntouched() {
    #expect(TaskBoardApprovedAtPickerValue.sanitizedApprovedAt("") == "")
    #expect(
      TaskBoardApprovedAtPickerValue.sanitizedApprovedAt("2026-05-14T10:00:00Z")
        == "2026-05-14T10:00:00Z"
    )
  }

  @Test("Sanitizing clears a timestamp the old free-text field let through malformed")
  func sanitizingClearsMalformedApprovedAt() {
    #expect(TaskBoardApprovedAtPickerValue.sanitizedApprovedAt("not a real date") == "")
  }
}
