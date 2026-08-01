import HarnessMonitorKit
import SwiftUI

struct TaskBoardWorkflowValueRow: View {
  let label: String
  let value: String
  var monospaced = false
  var destination: URL?
  @Environment(\.fontScale)
  private var fontScale

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
      Text(label)
        .font(captionFont)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      if let destination {
        Link(destination: destination) {
          valueText
        }
        .foregroundStyle(HarnessMonitorTheme.accent.opacity(0.72))
      } else {
        valueText
          .foregroundStyle(HarnessMonitorTheme.ink)
          .textSelection(.enabled)
      }
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingSM)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
  }

  private var valueText: some View {
    Text(value)
      .font(monospaced ? captionFont.monospaced() : captionSemibold)
      .lineLimit(1)
      .truncationMode(monospaced ? .middle : .tail)
      .multilineTextAlignment(.trailing)
      .help(value)
  }

  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }
}

extension View {
  func taskBoardWorkflowCard() -> some View {
    frame(maxWidth: .infinity, alignment: .leading)
      .background(HarnessMonitorTheme.ink.opacity(0.04), in: .rect(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(HarnessMonitorTheme.ink.opacity(0.1))
      }
  }
}

extension String {
  var withoutTrailingPeriod: String {
    var prose = trimmingCharacters(in: .whitespacesAndNewlines)
    while prose.hasSuffix(".") {
      prose.removeLast()
      prose = prose.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return prose
  }
}

extension TaskBoardWorkflowAttemptProgress {
  var runtimeSummary: String? {
    let summary = [runtime, model].compactMap(\.self).joined(separator: " · ")
    return summary.isEmpty ? nil : summary
  }
}
