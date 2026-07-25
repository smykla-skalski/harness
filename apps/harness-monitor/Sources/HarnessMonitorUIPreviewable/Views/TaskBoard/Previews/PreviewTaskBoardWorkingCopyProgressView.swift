import HarnessMonitorKit
import SwiftUI

private let previewNow = Date(timeIntervalSince1970: 1_000)

private func previewEntry(
  phase: String,
  done: UInt64,
  total: UInt64?,
  blocked: Bool = false,
  advancedSecondsAgo: TimeInterval = 0
) -> TaskBoardWorkingCopyProgressTracker.Entry {
  TaskBoardWorkingCopyProgressTracker.Entry(
    progress: TaskBoardWorkingCopyProgress(
      kind: .advanced,
      repoFullName: "acme/widgets",
      phase: phase,
      done: done,
      total: total,
      blocked: blocked
    ),
    lastAdvancedAt: previewNow.addingTimeInterval(-advancedSecondsAgo)
  )
}

#Preview("Working copy progress") {
  VStack(alignment: .leading, spacing: 12) {
    TaskBoardWorkingCopyProgressView(
      repository: "acme/widgets",
      entry: previewEntry(phase: "Receiving objects", done: 40, total: 100),
      now: previewNow
    )
    TaskBoardWorkingCopyProgressView(
      repository: "acme/widgets",
      entry: previewEntry(phase: "Counting objects", done: 7, total: nil),
      now: previewNow
    )
    TaskBoardWorkingCopyProgressView(
      repository: "acme/widgets",
      entry: previewEntry(
        phase: "Receiving objects",
        done: 40,
        total: 100,
        advancedSecondsAgo: 30
      ),
      now: previewNow
    )
    TaskBoardWorkingCopyProgressView(
      repository: "acme/widgets",
      entry: previewEntry(phase: "Receiving objects", done: 40, total: 100, blocked: true),
      now: previewNow
    )
  }
  .padding()
  .frame(width: 320)
}
