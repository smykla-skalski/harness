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
    var rowsByID: [String: ToolCallTimelineRow] = [:]
    for row in entries.compactMap(ToolCallTimelineRow.init(entry:)).sorted(by: {
      if $0.recordedAt != $1.recordedAt {
        return $0.recordedAt < $1.recordedAt
      }
      return $0.entryId < $1.entryId
    }) {
      rowsByID[row.id] = rowsByID[row.id]?.merging(row) ?? row
    }
    return rowsByID.values.sorted {
      if $0.recordedAt != $1.recordedAt {
        return $0.recordedAt > $1.recordedAt
      }
      return $0.entryId < $1.entryId
    }
  }
}

struct ToolCallTimelineRow: Identifiable, Equatable {
  let id: String
  let entryId: String
  let recordedAt: String
  let title: String
  let detail: String
  let status: Status

  enum Status: Equatable {
    case started
    case completed
    case failed
  }

  init?(entry: TimelineEntry) {
    guard let event = Self.toolEventPayload(from: entry),
      let type = event.stringValue(for: "type")
    else {
      return nil
    }
    let status = Self.status(forEntryKind: entry.kind, eventType: type, event: event)
    guard let status else { return nil }

    let toolName: String =
      if let value = event.stringValue(for: "tool_name") {
        value
      } else {
        "Tool"
      }
    id = event.stringValue(for: "invocation_id") ?? entry.entryId
    entryId = entry.entryId
    recordedAt = entry.recordedAt
    title = toolName
    detail = entry.summary
    self.status = status
  }

  private static func toolEventPayload(from entry: TimelineEntry) -> [String: JSONValue]? {
    let canonicalKinds = ["tool_invocation", "tool_result", "tool_result_error"]
    guard canonicalKinds.contains(entry.kind) || entry.kind == "conversation_event",
      case .object(let payload) = entry.payload
    else {
      return nil
    }
    let eventPayload = payload["event"] ?? payload["kind"]
    guard case .object(let event)? = eventPayload else {
      return nil
    }
    return event
  }

  private static func status(
    forEntryKind entryKind: String,
    eventType: String,
    event: [String: JSONValue]
  ) -> Status? {
    switch entryKind {
    case "tool_invocation":
      return .started
    case "tool_result_error":
      return .failed
    case "tool_result":
      return event.boolValue(for: "is_error") == true ? .failed : .completed
    case "conversation_event":
      switch eventType {
      case "tool_invocation":
        return .started
      case "tool_result":
        return event.boolValue(for: "is_error") == true ? .failed : .completed
      default:
        return nil
      }
    default:
      return nil
    }
  }

  func merging(_ newer: Self) -> Self {
    guard isStarted || !newer.isStarted else {
      return self
    }
    return newer
  }

  private var isStarted: Bool {
    switch status {
    case .started:
      true
    case .completed, .failed:
      false
    }
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

extension [String: JSONValue] {
  fileprivate func stringValue(for key: String) -> String? {
    guard case .string(let value)? = self[key] else {
      return nil
    }
    return value
  }

  fileprivate func boolValue(for key: String) -> Bool? {
    guard case .bool(let value)? = self[key] else {
      return nil
    }
    return value
  }
}
