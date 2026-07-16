import HarnessMonitorKit
import SwiftUI

func priorityColor(for priority: TaskBoardPriority) -> Color {
  switch priority {
  case .critical:
    HarnessMonitorTheme.danger
  case .high:
    HarnessMonitorTheme.caution
  case .medium:
    HarnessMonitorTheme.accent
  case .low:
    HarnessMonitorTheme.secondaryInk
  }
}

func taskBoardApprovalColor(for state: TaskBoardPlanApprovalState) -> Color {
  switch state {
  case .approved:
    HarnessMonitorTheme.success
  case .submitted:
    HarnessMonitorTheme.caution
  case .notApproved:
    HarnessMonitorTheme.secondaryInk
  }
}

func taskBoardStatusColor(for status: TaskBoardStatus) -> Color {
  switch status {
  case .failed, .blocked:
    HarnessMonitorTheme.danger
  case .agenticReview, .planReview, .testing, .inReview, .toReview:
    HarnessMonitorTheme.caution
  case .humanRequired, .needsYou:
    HarnessMonitorTheme.danger
  case .planning, .inProgress:
    HarnessMonitorTheme.warmAccent
  case .backlog, .new, .todo:
    HarnessMonitorTheme.accent
  case .done:
    HarnessMonitorTheme.secondaryInk
  case .unknown:
    HarnessMonitorTheme.secondaryInk
  }
}
