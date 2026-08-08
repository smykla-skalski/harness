import HarnessMonitorKit
import SwiftUI

/// The percentage a worker last reported, as a labelled bar. Absent progress
/// renders nothing rather than a zero bar, which would read as "no work done".
struct TaskBoardWorkerProgressBar: View {
  let percent: UInt8
  @Environment(\.fontScale)
  private var fontScale

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        Text("Reported progress")
          .font(HarnessMonitorTextSize.scaledFont(.caption, by: fontScale))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        Text("\(percent)%")
          .font(
            HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
              .monospacedDigit()
          )
          .foregroundStyle(HarnessMonitorTheme.ink)
      }
      ProgressView(value: Double(percent), total: 100)
        .progressViewStyle(.linear)
        .tint(fillTint)
    }
    .padding(HarnessMonitorTheme.spacingSM)
    .taskBoardWorkflowCard()
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Reported progress")
    .accessibilityValue("\(percent) percent")
  }

  /// Caution while work is outstanding, blending to success as the worker
  /// closes it out, so a glance at the bar carries the same reading as the
  /// number beside it. Mixed perceptually rather than by device components:
  /// blending orange into green through sRGB passes through a muddy olive,
  /// which reads as a third status the theme does not have.
  ///
  /// The percentage sits next to the bar, so this colour reinforces the value
  /// rather than being the only way to read it.
  private var fillTint: Color {
    HarnessMonitorTheme.caution.mix(
      with: HarnessMonitorTheme.success,
      by: Double(min(percent, 100)) / 100,
      in: .perceptual
    )
  }
}

/// The append-only checkpoint log, newest first.
struct TaskBoardWorkerCheckpointsCard: View {
  let checkpoints: [TaskBoardWorkerCheckpointPresentation]

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(checkpoints.enumerated()), id: \.element.id) { index, checkpoint in
        TaskBoardWorkerCheckpointRow(checkpoint: checkpoint)
          .padding(HarnessMonitorTheme.spacingSM)
        if index != checkpoints.indices.last {
          Divider()
        }
      }
    }
    .taskBoardWorkflowCard()
  }
}

private struct TaskBoardWorkerCheckpointRow: View {
  let checkpoint: TaskBoardWorkerCheckpointPresentation
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration
  // Optional, so this row still renders outside the board's own surfaces (a
  // preview, a detail route opened on its own) instead of trapping on a missing
  // clock. When the board does provide one, every relative label on screen
  // ticks together rather than each row owning a timer.
  @Environment(TaskBoardRelativeTimeClock.self)
  private var relativeTimeClock: TaskBoardRelativeTimeClock?

  var body: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
      Text("\(checkpoint.sequence)")
        .font(captionSemibold.monospacedDigit())
        .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
        .frame(width: 18, alignment: .center)
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Text(checkpoint.summary)
          .font(captionSemibold)
          .foregroundStyle(HarnessMonitorTheme.ink)
          .fixedSize(horizontal: false, vertical: true)
        Text(metadata)
          .font(captionFont)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .help(absoluteRecordedAt)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Checkpoint \(checkpoint.sequence)")
    .accessibilityValue("\(checkpoint.summary). \(accessibleMetadata)")
  }

  /// Scannable by design: the log is read top-down for "when did what happen",
  /// which relative ages answer faster than timestamps. The exact time stays
  /// one hover away.
  private var relativeRecordedAt: String {
    let label = formatCompactRelativeUpdatedAt(
      checkpoint.recordedAt,
      reference: relativeTimeClock?.referenceDate ?? .now
    )
    return label.isEmpty ? absoluteRecordedAt : label
  }

  private var absoluteRecordedAt: String {
    formatTimestamp(checkpoint.recordedAt, configuration: dateTimeConfiguration)
  }

  private var metadata: String {
    joined(time: relativeRecordedAt)
  }

  /// VoiceOver gets the unabbreviated age, matching how the board's cards
  /// announce theirs.
  private var accessibleMetadata: String {
    joined(
      time: formatRelativeUpdatedAt(
        checkpoint.recordedAt,
        reference: relativeTimeClock?.referenceDate ?? .now
      )
    )
  }

  private func joined(time: String) -> String {
    var parts = [checkpoint.actor]
    if let percent = checkpoint.progressPercent {
      parts.append("\(percent)%")
    }
    parts.append(time)
    return parts.joined(separator: " · ")
  }

  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }
}
