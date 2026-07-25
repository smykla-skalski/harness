import Foundation
import HarnessMonitorKit
import SwiftUI

@MainActor
@Observable
final class TaskBoardItemCreationOutcome {
  var succeeded = false
}

struct TaskBoardTriageInspectorLoadKey: Hashable {
  let itemID: String
  let updatedAt: String
}

@MainActor private let taskBoardApprovedAtSubmissionFormatter: ISO8601DateFormatter = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  return formatter
}()

/// Bridges the RFC3339 `approvedAt` draft string to the `Date` a native
/// `DatePicker` needs. `fallback` covers both the never-approved case and a
/// pre-existing string the old free-text field let through malformed.
enum TaskBoardApprovedAtPickerValue {
  @MainActor
  static func date(fromApprovedAt approvedAt: String, fallback: Date) -> Date {
    guard !approvedAt.isEmpty else { return fallback }
    return TaskBoardCardDateParsing.parse(approvedAt) ?? fallback
  }

  @MainActor
  static func approvedAtString(from date: Date) -> String {
    taskBoardApprovedAtSubmissionFormatter.string(from: date)
  }

  /// Clears a non-empty `approvedAt` the old free-text field let through
  /// malformed, so the picker's valid-looking fallback display can't mask a
  /// bad string that would still round-trip into the approve/update request.
  @MainActor
  static func sanitizedApprovedAt(_ approvedAt: String) -> String {
    approvedAt.isEmpty || TaskBoardCardDateParsing.parse(approvedAt) != nil ? approvedAt : ""
  }
}
