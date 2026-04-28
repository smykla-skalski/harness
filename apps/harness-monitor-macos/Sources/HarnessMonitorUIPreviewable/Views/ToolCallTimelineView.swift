import HarnessMonitorKit
import SwiftUI

struct ToolCallTimelineView: View {
  let entries: [TimelineEntry]
  let stopSession: () -> Void
  @State private var rows: [ToolCallTimelineRow] = []

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      HStack {
        Text("Tool calls")
          .scaledFont(.headline)
          .accessibilityAddTraits(.isHeader)
        Spacer()
        Button(role: .destructive, action: stopSession) {
          Label("Stop session", systemImage: "stop.fill")
        }
        .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.danger)
      }
      LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        ForEach(rows) { row in
          HStack(spacing: HarnessMonitorTheme.itemSpacing) {
            Image(systemName: row.symbolName)
              .foregroundStyle(row.tint)
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
              Text(row.title)
                .scaledFont(.subheadline.weight(.semibold))
                .lineLimit(1)
              Text(row.detail)
                .scaledFont(.caption)
                .foregroundStyle(HarnessMonitorTheme.secondaryInk)
                .lineLimit(2)
            }
            Spacer(minLength: 0)
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel(row.accessibilityLabel)
          .accessibilityValue(row.accessibilityValue)
          .accessibilityIdentifier(HarnessMonitorAccessibility.toolCallTimelineRow(row.id))
        }
      }
    }
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.toolCallTimeline)
    .task(id: entries.map(\.entryId).joined(separator: "|")) {
      let nextRows = Self.materialiseRows(from: entries)
      await MainActor.run {
        rows = nextRows
      }
    }
  }

  static func materialiseRows(from entries: [TimelineEntry]) -> [ToolCallTimelineRow] {
    entries.compactMap(ToolCallTimelineRow.init(entry:))
  }
}

struct ToolCallTimelineRow: Identifiable, Equatable {
  let id: String
  let title: String
  let detail: String
  let status: Status

  enum Status: Equatable {
    case started
    case completed
    case failed
  }

  init?(entry: TimelineEntry) {
    guard entry.kind == "conversation_event" else { return nil }
    guard case .object(let payload) = entry.payload,
      case .object(let kind)? = payload["kind"],
      case .string(let type)? = kind["type"],
      type == "tool_invocation" || type == "tool_result"
    else {
      return nil
    }
    let toolName: String =
      if case .string(let value)? = kind["tool_name"] {
        value
      } else {
        "Tool"
      }
    let isError =
      if case .bool(let value)? = kind["is_error"] {
        value
      } else {
        false
      }
    id = entry.entryId
    title = toolName
    detail = entry.summary
    status = type == "tool_invocation" ? .started : (isError ? .failed : .completed)
  }

  var symbolName: String {
    switch status {
    case .started:
      "clock"
    case .completed:
      "checkmark.circle.fill"
    case .failed:
      "xmark.octagon.fill"
    }
  }

  var tint: Color {
    switch status {
    case .started:
      HarnessMonitorTheme.secondaryInk
    case .completed:
      HarnessMonitorTheme.success
    case .failed:
      HarnessMonitorTheme.danger
    }
  }

  var accessibilityLabel: String {
    switch status {
    case .started:
      title
    case .completed:
      "\(title), completed"
    case .failed:
      "\(title), failed"
    }
  }

  var accessibilityValue: String {
    switch status {
    case .started:
      "In progress"
    case .completed:
      "Completed"
    case .failed:
      "Failed"
    }
  }
}
