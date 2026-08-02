import Foundation
import HarnessMonitorKit

struct TaskBoardReviewTerminalPresentation {
  let report: TaskBoardAiReviewReportRecord
  let status: TaskBoardAiReviewReportStatus

  var showsGeneratedSections: Bool {
    status == .completed || hasGeneratedResult
  }

  var visiblePartialOutput: String? {
    guard showsGeneratedSections else { return nil }
    return report.partialOutput?.taskBoardNonemptyReviewText
  }

  var terminalDetail: String? {
    let reason = report.terminalReason?.taskBoardReviewMessage
    guard status != .completed, !hasGeneratedResult else { return reason }
    guard let reason else { return emptyTerminalDetail }
    return "\(reason), so no summary or findings were generated"
  }

  private var hasGeneratedResult: Bool {
    report.summary?.taskBoardNonemptyReviewText != nil || !report.findings.isEmpty
  }

  private var emptyTerminalDetail: String {
    switch status {
    case .completed:
      "No summary or findings were generated"
    case .failed:
      "The review failed before a summary or findings were generated"
    case .cancelled:
      "The review was cancelled before a summary or findings were generated"
    }
  }
}

extension String {
  fileprivate var taskBoardNonemptyReviewText: String? {
    let normalized = trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  fileprivate var taskBoardReviewMessage: String? {
    guard var normalized = taskBoardNonemptyReviewText else { return nil }
    while normalized.last == "." {
      normalized.removeLast()
      normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return normalized.isEmpty ? nil : normalized
  }
}
