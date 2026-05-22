import AppKit
import Foundation
import HarnessMonitorKit
import SwiftUI

// MARK: - Stub (TEMPORARY — Unit 1 supersedes; coordinator removes during cherry-pick)
//
// Unit 1 owns the canonical `redactSupervisorPayloadJSON(_:)`. While that unit
// has not landed in this worktree, fall back to a passthrough so the inspector
// can still build and render fixtures during preview authoring. The local
// implementation is `fileprivate` so the symbol resolves to the public one
// once Unit 1 lands and the coordinator drops this block.
private func redactSupervisorPayloadJSON(_ raw: String) -> String { raw }
// MARK: - End stub

/// Shared decoder used by `AuditTimelinePayloadInspectorView`. Allocated at
/// module scope so the decode-once-in-init contract does not allocate a fresh
/// decoder per inspector instance.
private let auditInspectorPayloadDecoder = JSONDecoder()

/// Collapsible tree view over a `SupervisorEvent.payloadJSON` blob.
///
/// The raw JSON is redacted via `redactSupervisorPayloadJSON(_:)` and decoded
/// once in `init`. Subsequent body invalidations re-use the cached node tree
/// without re-allocating a `JSONDecoder` or re-running redaction, satisfying
/// the perf rule against per-body JSON work.
@MainActor
public struct AuditTimelinePayloadInspectorView: View {
  private let node: AuditPayloadNode
  private let errorMessage: String?

  public init(payloadJSON: String) {
    let redacted = redactSupervisorPayloadJSON(payloadJSON)
    let trimmed = redacted.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      node = .leaf(label: nil, summary: AuditPayloadSummary.empty)
      errorMessage = nil
      return
    }
    guard
      let data = trimmed.data(using: .utf8),
      let decoded = try? auditInspectorPayloadDecoder.decode(JSONValue.self, from: data)
    else {
      node = .leaf(label: nil, summary: AuditPayloadSummary(rawText: trimmed))
      errorMessage = "Payload is not valid JSON. Showing raw text."
      return
    }
    node = AuditPayloadNode.from(value: decoded, label: nil)
    errorMessage = nil
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      if let errorMessage {
        Text(errorMessage)
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.caution)
          .fixedSize(horizontal: false, vertical: true)
      }
      AuditPayloadNodeView(node: node, depth: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.audit.payload.inspector")
  }
}

// MARK: - Node tree

/// Recursive payload node used by the inspector. Each container node carries
/// the JSON pretty-printed string for the subtree it represents so the
/// per-row copy button can paste just that scope rather than the full
/// document.
indirect enum AuditPayloadNode {
  case leaf(label: String?, summary: AuditPayloadSummary)
  case container(
    label: String?,
    kind: AuditPayloadContainerKind,
    children: [AuditPayloadNode],
    prettyJSON: String
  )

  static func from(value: JSONValue, label: String?) -> AuditPayloadNode {
    switch value {
    case .object(let dictionary):
      let sortedKeys = dictionary.keys.sorted()
      let children = sortedKeys.map { key in
        AuditPayloadNode.from(value: dictionary[key] ?? .null, label: key)
      }
      return .container(
        label: label,
        kind: .object,
        children: children,
        prettyJSON: value.prettyPrintedJSONString()
      )
    case .array(let items):
      let children = items.enumerated().map { index, item in
        AuditPayloadNode.from(value: item, label: "[\(index)]")
      }
      return .container(
        label: label,
        kind: .array,
        children: children,
        prettyJSON: value.prettyPrintedJSONString()
      )
    case .bool, .null, .number, .string:
      return .leaf(label: label, summary: AuditPayloadSummary(value: value))
    }
  }
}

enum AuditPayloadContainerKind: Sendable {
  case object
  case array
}

struct AuditPayloadSummary: Sendable {
  let displayValue: String
  let copyValue: String

  init(value: JSONValue) {
    switch value {
    case .null:
      displayValue = "null"
      copyValue = "null"
    case .bool(let flag):
      displayValue = flag ? "true" : "false"
      copyValue = displayValue
    case .number(let number):
      let formatted = AuditPayloadSummary.formatNumber(number)
      displayValue = formatted
      copyValue = formatted
    case .string(let text):
      displayValue = text
      copyValue = text
    case .array, .object:
      displayValue = "(complex)"
      copyValue = ""
    }
  }

  init(rawText: String) {
    displayValue = rawText
    copyValue = rawText
  }

  static let empty = AuditPayloadSummary(rawText: "")

  private static func formatNumber(_ value: Double) -> String {
    if value.rounded() == value, abs(value) < 1e15 {
      return String(Int64(value))
    }
    return String(value)
  }
}

// MARK: - Node view

private struct AuditPayloadNodeView: View {
  let node: AuditPayloadNode
  let depth: Int

  var body: some View {
    switch node {
    case .leaf(let label, let summary):
      AuditPayloadLeafRow(
        label: label,
        summary: summary,
        depth: depth
      )
    case .container(let label, let kind, let children, let prettyJSON):
      AuditPayloadContainerRow(
        label: label,
        kind: kind,
        children: children,
        depth: depth,
        subtreePrettyJSON: prettyJSON
      )
    }
  }
}

private struct AuditPayloadContainerRow: View {
  let label: String?
  let kind: AuditPayloadContainerKind
  let children: [AuditPayloadNode]
  let depth: Int
  let subtreePrettyJSON: String

  @State private var isExpanded: Bool

  init(
    label: String?,
    kind: AuditPayloadContainerKind,
    children: [AuditPayloadNode],
    depth: Int,
    subtreePrettyJSON: String
  ) {
    self.label = label
    self.kind = kind
    self.children = children
    self.depth = depth
    self.subtreePrettyJSON = subtreePrettyJSON
    // Top level expands by default; nested containers stay collapsed so the
    // viewer can drill in without scrolling past leaf clusters.
    _isExpanded = State(initialValue: depth == 0)
  }

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        ForEach(Array(children.enumerated()), id: \.offset) { _, child in
          AuditPayloadNodeView(node: child, depth: depth + 1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingXS) {
        Text(headerLabel)
          .scaledFont(.caption.monospaced().weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.ink)
        Text(summary)
          .scaledFont(.caption.monospaced())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Spacer(minLength: HarnessMonitorTheme.spacingXS)
        AuditPayloadCopyButton(
          text: copyText,
          accessibilityHint: "Copies this redacted subtree as JSON"
        )
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .contain)
      .accessibilityLabel(Text("\(headerLabel) \(summary)"))
    }
  }

  private var headerLabel: String {
    if let label = label, !label.isEmpty {
      return "\(label):"
    }
    return kind == .object ? "{}" : "[]"
  }

  private var summary: String {
    switch kind {
    case .object:
      return children.count == 1 ? "1 key" : "\(children.count) keys"
    case .array:
      return children.count == 1 ? "1 item" : "\(children.count) items"
    }
  }

  private var copyText: String {
    if let label = label, !label.isEmpty {
      return "\(label): \(subtreePrettyJSON)"
    }
    return subtreePrettyJSON
  }
}

private struct AuditPayloadLeafRow: View {
  let label: String?
  let summary: AuditPayloadSummary
  let depth: Int

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingXS) {
      if let label = label, !label.isEmpty {
        Text("\(label):")
          .scaledFont(.caption.monospaced().weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.ink)
      }
      Text(displayValue)
        .scaledFont(.caption.monospaced())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: HarnessMonitorTheme.spacingXS)
      AuditPayloadCopyButton(
        text: copyText,
        accessibilityHint: "Copies the redacted key and value"
      )
    }
    .padding(.vertical, 1)
  }

  private var displayValue: String {
    summary.displayValue.isEmpty ? "(empty)" : summary.displayValue
  }

  private var copyText: String {
    if let label = label, !label.isEmpty {
      return "\(label): \(summary.copyValue)"
    }
    return summary.copyValue
  }
}

private struct AuditPayloadCopyButton: View {
  let text: String
  let accessibilityHint: String

  var body: some View {
    Button {
      copy()
    } label: {
      Image(systemName: "doc.on.doc")
        .imageScale(.small)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .accessibilityHidden(true)
    }
    .buttonStyle(.borderless)
    .help("Copy")
    .accessibilityLabel(Text("Copy"))
    .accessibilityHint(Text(accessibilityHint))
  }

  private func copy() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }
}
