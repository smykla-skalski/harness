import Foundation
import SwiftUI

enum TaskBoardAutomationAccessibility {
  static func runRowID(for runID: String) -> String {
    "harness.task-board.automation.run.\(escapedIdentifierSegment(runID))"
  }

  static func stageRowID(for stageID: String) -> String {
    "harness.task-board.automation.stage.\(escapedIdentifierSegment(stageID))"
  }

  private static func escapedIdentifierSegment(_ value: String) -> String {
    guard !value.isEmpty else { return "~" }
    return value.utf8.map { byte in
      if byte == 45 || byte == 46 || byte == 95
        || (48...57).contains(byte)
        || (65...90).contains(byte)
        || (97...122).contains(byte)
      {
        return String(decoding: [byte], as: UTF8.self)
      }
      return String(format: "~%02X", byte)
    }
    .joined()
  }
}

extension TaskBoardAutomationTone {
  var color: Color {
    switch self {
    case .accent:
      HarnessMonitorTheme.accent
    case .danger:
      HarnessMonitorTheme.danger
    case .neutral:
      HarnessMonitorTheme.secondaryInk
    case .success:
      HarnessMonitorTheme.success
    case .warning:
      HarnessMonitorTheme.caution
    }
  }
}

struct TaskBoardAutomationSubsectionHeader: View {
  let title: String

  var body: some View {
    Text(title)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.primary)
      .padding(.top, HarnessMonitorTheme.spacingMD)
      .padding(.bottom, HarnessMonitorTheme.spacingXS)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityAddTraits(.isHeader)
  }
}

struct TaskBoardAutomationPillFlow: View {
  let pills: [TaskBoardAutomationPill]

  var body: some View {
    HarnessMonitorWrapLayout(
      spacing: HarnessMonitorTheme.spacingXS,
      lineSpacing: HarnessMonitorTheme.spacingXS
    ) {
      ForEach(pills) { pill in
        TaskBoardSummaryPill(
          value: pill.value,
          label: pill.label,
          tint: pill.tone.color
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct TaskBoardAutomationValueRows: View {
  let rows: [TaskBoardAutomationValueRow]

  var body: some View {
    ForEach(rows) { row in
      TaskBoardOperationsFormRow(row.label) {
        Text(row.value)
          .font(.caption)
          .foregroundStyle(row.tone.color)
          .lineLimit(2)
          .truncationMode(.middle)
          .multilineTextAlignment(.trailing)
          .textSelection(.enabled)
          .help(row.accessibilityValue)
      }
      .accessibilityElement(children: .combine)
      .accessibilityValue(row.accessibilityValue)
    }
  }
}

struct TaskBoardAutomationPlaceholder: View {
  let title: String
  let systemImage: String
  var showsProgress = false

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      if showsProgress {
        ProgressView()
          .controlSize(.small)
          .accessibilityHidden(true)
      } else {
        Image(systemName: systemImage)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .accessibilityHidden(true)
      }
      Text(title)
        .font(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .padding(.vertical, HarnessMonitorTheme.spacingMD)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}
