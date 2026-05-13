import HarnessMonitorKit
import SwiftUI

extension [WorkItem] {
  func queued(for agentID: String) -> [WorkItem] {
    filter { task in
      task.assignedTo == agentID && task.isQueuedForWorker
    }
    .sorted { lhs, rhs in
      (lhs.queuedAt ?? lhs.updatedAt, lhs.taskId) < (rhs.queuedAt ?? rhs.updatedAt, rhs.taskId)
    }
  }
}

struct RoleTintRGB {
  let red: CGFloat
  let green: CGFloat
  let blue: CGFloat
}

struct DropTargetPulseBorder: View {
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  var body: some View {
    RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
      .stroke(HarnessMonitorTheme.success, lineWidth: 1.5)
      .opacity(reduceMotion ? 0.6 : 0.35)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}
