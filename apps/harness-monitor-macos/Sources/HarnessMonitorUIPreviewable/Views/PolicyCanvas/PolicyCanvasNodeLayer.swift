import SwiftUI

struct PolicyCanvasNodeLayer: View {
  let viewModel: PolicyCanvasViewModel
  // P27 keyboard focus ring + tab order: a parent-level @FocusState drives
  // keyboard Tab/Shift+Tab cycling across the visual focus order, and a
  // mirrored @AccessibilityFocusState exposes the same selection to
  // VoiceOver so the rotor entries can route focus to the matching card.
  // The two wrappers track separately because their `equals:` overloads use
  // distinct binding types and SwiftUI does not auto-bridge between them.
  @FocusState private var focusedNodeID: String?
  @AccessibilityFocusState private var accessibilityFocusedNodeID: String?

  var body: some View {
    let severityMap = viewModel.nodeSeverityMap
    let focusOrder = viewModel.accessibilityNodeFocusOrder()
    let orderedNodes = focusOrder.compactMap { id in
      viewModel.nodes.first { $0.id == id }
    }
    ForEach(orderedNodes) { node in
      PolicyCanvasNodeCard(
        node: node,
        isSelected: viewModel.selection == .node(node.id),
        isFocused: focusedNodeID == node.id || accessibilityFocusedNodeID == node.id,
        severity: severityMap[node.id],
        viewModel: viewModel
      )
      .offset(x: node.position.x, y: node.position.y)
      .focusable()
      .focused($focusedNodeID, equals: node.id)
      .accessibilityFocused($accessibilityFocusedNodeID, equals: node.id)
      .gesture(
        DragGesture(minimumDistance: 3)
          .onChanged { value in
            viewModel.dragNode(node.id, translation: value.translation)
          }
          .onEnded { value in
            viewModel.endNodeDrag(node.id, translation: value.translation)
          }
      )
      .onTapGesture {
        viewModel.select(.node(node.id))
        focusedNodeID = node.id
      }
    }
  }
}

struct PolicyCanvasNodeCard: View {
  let node: PolicyCanvasNode
  let isSelected: Bool
  let isFocused: Bool
  let severity: PolicyCanvasIssueSeverity?
  let viewModel: PolicyCanvasViewModel

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 8)
        .fill(Color(red: 0.10, green: 0.12, blue: 0.16).opacity(0.95))
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(strokeColor, lineWidth: severity == nil ? 1.2 : 1.8)
        }
        .overlay {
          // P27 focus ring: 1.5pt accent stroke when keyboard focus lands on
          // this card. Rendered above the severity/selection stroke so the
          // ring is always visible when focus exists, even on validation-
          // error nodes whose severity stroke would otherwise dominate.
          if isFocused {
            RoundedRectangle(cornerRadius: 8)
              .stroke(node.kind.accentColor.opacity(0.98), lineWidth: 1.5)
              .padding(-1)
          }
        }
        .shadow(color: .black.opacity(0.34), radius: 12, x: 0, y: 8)

      HStack(alignment: .top, spacing: 10) {
        Image(systemName: node.kind.symbolName)
          .scaledFont(.system(size: 16, weight: .semibold))
          .foregroundStyle(node.kind.accentColor)
          .frame(width: 24, height: 24)
          .background(node.kind.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))

        VStack(alignment: .leading, spacing: 5) {
          // P26 Dynamic Type: the fixed `nodeSize.height` is load-bearing for
          // edge routing (port anchors are derived from layout coords, not
          // measured frames). Letting text reflow inside via lineLimit(2) +
          // minimumScaleFactor keeps AX5 legible without dragging the whole
          // layout topology with it.
          Text(node.title)
            .scaledFont(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(2)
            .minimumScaleFactor(0.85)

          Text(node.subtitle)
            .scaledFont(.caption)
            // P29 contrast bump: 0.62 -> 0.78 puts the subtitle above the
            // ~5.5:1 AA threshold on the node's `#191F29` surface (was ~4:1).
            .foregroundStyle(.white.opacity(0.78))
            .lineLimit(1)
            .minimumScaleFactor(0.85)

          if let groupID = node.groupID, let group = viewModel.group(groupID) {
            Text(group.title)
              .scaledFont(.caption2.weight(.medium))
              .foregroundStyle(group.tone.color.opacity(0.95))
              .lineLimit(1)
              .minimumScaleFactor(0.85)
          }
        }

        Spacer(minLength: 0)
      }
      .padding(12)

      PolicyCanvasPortColumn(
        node: node,
        ports: node.inputPorts,
        alignment: .leading,
        viewModel: viewModel
      )

      PolicyCanvasPortColumn(
        node: node,
        ports: node.outputPorts,
        alignment: .trailing,
        viewModel: viewModel
      )

      PolicyCanvasPortColumn(
        node: node,
        ports: node.inputPorts,
        alignment: .top,
        viewModel: viewModel,
        isAuxiliary: true
      )

      PolicyCanvasPortColumn(
        node: node,
        ports: node.outputPorts,
        alignment: .bottom,
        viewModel: viewModel,
        isAuxiliary: true
      )

      if let severity {
        severityBadge(for: severity)
      }
    }
    .frame(width: PolicyCanvasLayout.nodeSize.width, height: PolicyCanvasLayout.nodeSize.height)
    // P57: `.ignore` (paired with composed label/value) avoids the
    // contradictory-rotor case where `.contain` would expose children
    // individually while a parent label was set. Children carry their own
    // a11y where needed (severity badge is .accessibilityHidden, port views
    // own their labels).
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(viewModel.accessibilityLabel(for: node))
    .accessibilityValue(accessibilityValue)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasNode(node.id))
    .modifier(
      PolicyCanvasNodeAccessibilityActions(
        viewModel: viewModel,
        nodeID: node.id
      )
    )
  }

  private var strokeColor: Color {
    if let severity {
      return severity.accentColor.opacity(isSelected ? 0.98 : 0.82)
    }
    return node.kind.accentColor.opacity(isSelected ? 0.95 : 0.34)
  }

  private var accessibilityValue: String {
    let base = viewModel.accessibilityValue(for: node)
    guard let severity else {
      return base
    }
    let issues = viewModel.allValidationIssues
      .filter { resolved in
        resolved.issue.nodeId == node.id || resolved.issue.nodeIds.contains(node.id)
      }
      .map { resolved in
        resolved.issue.message
      }
      .joined(separator: "; ")
    let prefix = "invalid: \(severity.displayLabel) - \(issues)"
    return base.isEmpty ? prefix : "\(prefix). \(base)"
  }

  private func severityBadge(for severity: PolicyCanvasIssueSeverity) -> some View {
    VStack {
      HStack {
        Spacer()
        Image(systemName: severity.systemImage)
          .scaledFont(.system(size: 13, weight: .semibold))
          .foregroundStyle(severity.accentColor)
          .padding(4)
          .background(.black.opacity(0.68), in: Circle())
          .overlay {
            Circle()
              .stroke(severity.accentColor.opacity(0.85), lineWidth: 1)
          }
          .offset(x: 8, y: -8)
          .accessibilityHidden(true)
      }
      Spacer()
    }
  }
}

/// P28 per-node accessibility actions modifier. Stamps Delete / Duplicate /
/// Open Inspector / Connect-to-first-reachable-input onto every node card so
/// VoiceOver users get the same commands the mouse drag/context-menu paths
/// expose. Built as a `ViewModifier` instead of inline `.accessibilityAction`
/// calls so the action closures don't allocate on every node card update.
private struct PolicyCanvasNodeAccessibilityActions: ViewModifier {
  let viewModel: PolicyCanvasViewModel
  let nodeID: String

  func body(content: Content) -> some View {
    content
      .accessibilityAction(named: Text("Delete")) {
        viewModel.select(.node(nodeID))
        viewModel.deleteNode(nodeID)
      }
      .accessibilityAction(named: Text("Duplicate")) {
        _ = viewModel.duplicateNode(nodeID)
      }
      .accessibilityAction(named: Text("Open inspector")) {
        viewModel.accessibilityOpenInspector(forNodeID: nodeID)
      }
      .accessibilityAction(named: Text("Connect")) {
        let targets = viewModel.accessibilityConnectableTargets(fromNodeID: nodeID)
        guard let first = targets.first else {
          return
        }
        _ = viewModel.accessibilityConnect(fromNodeID: nodeID, to: first)
      }
  }
}
