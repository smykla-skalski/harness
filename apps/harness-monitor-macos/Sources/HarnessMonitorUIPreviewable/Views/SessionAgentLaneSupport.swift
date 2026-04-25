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
      .modifier(PulseOpacityModifier(reduceMotion: reduceMotion))
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

struct PulseOpacityModifier: ViewModifier {
  let reduceMotion: Bool

  func body(content: Content) -> some View {
    if reduceMotion {
      content.opacity(0.6)
    } else {
      content.phaseAnimator([0.25, 0.7]) { border, opacity in
        border.opacity(opacity)
      } animation: { _ in
        .easeInOut(duration: 1.1)
      }
    }
  }
}
