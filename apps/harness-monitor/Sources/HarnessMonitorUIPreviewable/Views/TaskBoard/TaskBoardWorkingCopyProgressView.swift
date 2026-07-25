import HarnessMonitorKit
import SwiftUI

/// Live progress for one in-flight working-copy obtain.
///
/// Shared by both places a copy can be obtained - the deliver sheet's
/// `ResolveRepositoryDirectoriesSheet` and Settings'
/// `SettingsRepositoryWorkingDirectoriesSection` - so a clone reads the same way
/// wherever it was started.
///
/// A clone that reports a bounded phase gets a determinate bar; one that has not
/// been bounded yet keeps the indeterminate spinner, because inventing a
/// fraction would be worse than admitting there isn't one.
public struct TaskBoardWorkingCopyProgressView: View {
  private let repository: String
  private let entry: TaskBoardWorkingCopyProgressTracker.Entry
  private let now: Date

  public init(
    repository: String,
    entry: TaskBoardWorkingCopyProgressTracker.Entry,
    now: Date
  ) {
    self.repository = repository
    self.entry = entry
    self.now = now
  }

  private var isStalled: Bool {
    entry.isStalled(now: now)
  }

  private var label: String {
    if isStalled {
      return entry.progress.blocked ? "Waiting on the remote" : "No progress"
    }
    return entry.progress.phaseLabel ?? "Cloning"
  }

  public var body: some View {
    HStack(spacing: 6) {
      indicator
      Text(label)
        .font(.caption2)
        .foregroundStyle(isStalled ? HarnessMonitorTheme.caution : Color.secondary)
        .monospacedDigit()
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("taskBoardWorkingCopyProgress-\(repository)")
    .accessibilityLabel(Text("\(label) for \(repository)"))
  }

  @ViewBuilder private var indicator: some View {
    if isStalled {
      Image(systemName: "exclamationmark.triangle")
        .foregroundStyle(HarnessMonitorTheme.caution)
        .font(.caption2)
    } else if let fraction = entry.progress.fractionCompleted {
      ProgressView(value: fraction)
        .progressViewStyle(.linear)
        .frame(width: 60)
    } else {
      ProgressView()
        .controlSize(.small)
        .scaleEffect(0.5)
        .frame(width: 14, height: 14)
    }
  }
}
