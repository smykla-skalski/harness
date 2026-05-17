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
  /// Parent-pushed VO focus anchor for cross-pane shifts from the Cmd+F
  /// search palette (3J). Coexists with the local rotor-driven anchor above:
  /// both `.accessibilityFocused(...)` modifiers apply; whichever binding
  /// flips first wins on a given tick and the other is benign.
  let focusedComponent: AccessibilityFocusState<PolicyCanvasSelection?>.Binding
  /// P19 reduce-motion handle; mirrors the canvas-root system flag so the
  /// drop-end spring (P18) collapses to instant when the user has the
  /// system-wide reduce-motion accessibility setting on. The canvas-scoped
  /// override is optional with system fallback; see `PolicyCanvasMotion`.
  @Environment(\.policyCanvasReducedMotion)
  private var canvasReducedMotion
  @Environment(\.accessibilityReduceMotion)
  private var systemReduceMotion

  private var reducedMotion: Bool {
    canvasReducedMotion ?? systemReduceMotion
  }

  var body: some View {
    let severityMap = viewModel.nodeSeverityMap
    let focusOrder = viewModel.accessibilityNodeFocusOrder()
    let orderedNodes = focusOrder.compactMap { id in
      viewModel.nodes.first { $0.id == id }
    }
    ForEach(orderedNodes) { node in
      PolicyCanvasNodeCard(
        node: node,
        isSelected: viewModel.isSelected(.node(node.id)),
        isFocused: focusedNodeID == node.id || accessibilityFocusedNodeID == node.id,
        severity: severityMap[node.id],
        viewModel: viewModel
      )
      .offset(x: node.position.x, y: node.position.y)
      .focusable()
      .focused($focusedNodeID, equals: node.id)
      .accessibilityFocused($accessibilityFocusedNodeID, equals: node.id)
      .accessibilityFocused(focusedComponent, equals: .node(node.id))
      .gesture(
        DragGesture(minimumDistance: 3)
          .onChanged { value in
            viewModel.dragNode(node.id, translation: value.translation)
          }
          .onEnded { value in
            // P18 drop-end spring. The tick-rate `dragNode` writes during the
            // gesture are direct assignments (no animation — they already
            // follow the cursor); only the final position write through
            // `endNodeDrag` lands inside a `withAnimation` block so the
            // snap-to-grid step reads as a deliberate settle. Reduce-motion
            // collapses to a `nil` animation via `PolicyCanvasMotion.spring`.
            withAnimation(PolicyCanvasMotion.spring(reducedMotion: reducedMotion)) {
              viewModel.endNodeDrag(node.id, translation: value.translation)
            }
          }
      )
      .simultaneousGesture(
        TapGesture()
          .modifiers(.shift)
          .onEnded {
            viewModel.extendSelection(.node(node.id))
            focusedNodeID = node.id
          }
      )
      .onTapGesture {
        viewModel.select(.node(node.id))
        focusedNodeID = node.id
      }
      .contextMenu {
        if let groupID = node.groupID, viewModel.group(groupID) != nil {
          Button("Remove from group") {
            // Single-node operation; "Remove from group" only makes
            // sense for the row clicked, so it always targets this node.
            viewModel.select(.node(node.id))
            viewModel.removeNodeFromGroup(node.id)
          }
        }
        Button("Duplicate") {
          // Preserve a multi-selection that already includes the
          // right-clicked node: demoting to a single primary would drop
          // the rest of the shift-selected set silently. The duplicate
          // funnel picks up whatever `allSelections` already covers.
          if !viewModel.isSelected(.node(node.id)) {
            viewModel.select(.node(node.id))
          }
          viewModel.duplicateSelection()
        }
        Button("Delete", role: .destructive) {
          if viewModel.isSelected(.node(node.id)),
            !viewModel.secondarySelections.isEmpty
          {
            // Same rationale as Duplicate above: do not demote a
            // multi-selection to drop the other shift-selected nodes.
            _ = viewModel.deleteSelectedComponent()
          } else {
            viewModel.deleteNode(node.id)
          }
        }
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
  /// P19 reduce-motion handle for the P18 selection-mark transition. Pulled
  /// from the environment so the animation gating uses the same root-seeded
  /// bit the rest of the canvas reads. Canvas-scoped override is optional
  /// with system fallback; see `PolicyCanvasMotion`.
  @Environment(\.policyCanvasReducedMotion)
  private var canvasReducedMotion
  @Environment(\.accessibilityReduceMotion)
  private var systemReduceMotion

  private var reducedMotion: Bool {
    canvasReducedMotion ?? systemReduceMotion
  }

  private var focusTint: Color {
    Color(nsColor: .keyboardFocusIndicatorColor)
  }

  private var borderLineWidth: CGFloat {
    let base = severity == nil ? 1.2 : 1.8
    return isFocused ? base * 3 : base
  }

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 8)
        .fill(Color(red: 0.10, green: 0.12, blue: 0.16).opacity(0.95))
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(strokeColor, lineWidth: borderLineWidth)
            // P18 selection-mark: a short ease-out fade on the stroke color
            // when `isSelected` flips. Keyed on `isSelected` only — the
            // stroke also varies with severity (validation), but severity
            // changes already animate through the validation-cache
            // invalidation path; double-animating that surface would stack
            // two transitions on the same stroke. The wrapper hoists the
            // `Animation?` value out of the body so the per-frame
            // construction collapses to a `static let` lookup.
            .policyCanvasSelectionMark(value: isSelected, reducedMotion: reducedMotion)
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
          // minimumScaleFactor + allowsTightening keeps AX5 legible without
          // dragging the whole layout topology with it. The 0.7 floor (vs.
          // 0.85) trades a tighter title against the AX5 reality that an
          // 0.85-scaled headline still overflows the fixed card height; the
          // alternative (growing the card) would re-lay out every port anchor.
          Text(PolicyCanvasNodeTitleWrap.wrapSafe(node.title))
            .scaledFont(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(2)
            .truncationMode(.middle)
            .minimumScaleFactor(0.7)
            .allowsTightening(true)

          Text(node.subtitle)
            .scaledFont(.caption)
            // P29 contrast bump: 0.62 -> 0.78 puts the subtitle above the
            // ~5.5:1 AA threshold on the node's `#191F29` surface (was ~4:1).
            .foregroundStyle(.white.opacity(0.78))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .allowsTightening(true)
          // Group title intentionally absent here. The group's own chrome
          // (`PolicyCanvasGroupViews`) renders the title pinned to the
          // rectangle's top edge, so duplicating it on every member node
          // was redundant ink. The a11y value still names the group via
          // `viewModel.accessibilityValue(for:)` so screen-reader
          // navigation retains the membership context.
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
    if isFocused {
      return focusTint
    }
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
/// Open Inspector / per-target Connect actions onto every node card so
/// VoiceOver users get the same commands the mouse drag/context-menu paths
/// expose. Built as a `ViewModifier` instead of inline `.accessibilityAction`
/// calls so the action closures don't allocate on every node card update.
///
/// The Connect surface enumerates up to
/// `accessibilityConnectableTargetActionCap` reachable inputs as separately
/// named rotor entries (e.g. "Connect to Risk score event") so the VoiceOver
/// user knows which target an invocation wires before committing — the prior
/// single "Connect" action silently picked the first reachable input.
///
/// Per-target Connect actions live in the `.accessibilityActions { ForEach }`
/// block. The `ForEach` block accepts the ViewBuilder shape the per-target
/// enumeration needs without falling back to `AnyView` type-erasure (which
/// would re-erase the modifier chain on every node card update).
private struct PolicyCanvasNodeAccessibilityActions: ViewModifier {
  let viewModel: PolicyCanvasViewModel
  let nodeID: String

  func body(content: Content) -> some View {
    let connectTargets = viewModel.accessibilityConnectableNamedTargets(fromNodeID: nodeID)
    let canPaste = viewModel.clipboard != nil
    return
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
      .accessibilityAction(named: Text("Copy")) {
        // Targets the multi-selection if one exists, otherwise picks this
        // node so VO users get the same behavior as Cmd+C on the canvas.
        if !viewModel.isSelected(.node(nodeID)) {
          viewModel.select(.node(nodeID))
        }
        _ = viewModel.copySelectionToClipboard()
      }
      .accessibilityAction(named: Text("Rename")) {
        viewModel.accessibilityOpenInspector(forNodeID: nodeID)
      }
      // Plain nudge actions reuse the 10pt shift step the keyboard
      // shortcut surfaces; a 2pt bare-arrow step would be below the JND
      // for VO users who only get audio feedback "moved" without seeing
      // motion. The action set stays compact (4 directions) — finer
      // movement still routes through the rename / position field path.
      .accessibilityAction(named: Text("Nudge Up")) {
        if !viewModel.isSelected(.node(nodeID)) {
          viewModel.select(.node(nodeID))
        }
        _ = viewModel.nudgeSelection(by: CGSize(width: 0, height: -10))
      }
      .accessibilityAction(named: Text("Nudge Down")) {
        if !viewModel.isSelected(.node(nodeID)) {
          viewModel.select(.node(nodeID))
        }
        _ = viewModel.nudgeSelection(by: CGSize(width: 0, height: 10))
      }
      .accessibilityAction(named: Text("Nudge Left")) {
        if !viewModel.isSelected(.node(nodeID)) {
          viewModel.select(.node(nodeID))
        }
        _ = viewModel.nudgeSelection(by: CGSize(width: -10, height: 0))
      }
      .accessibilityAction(named: Text("Nudge Right")) {
        if !viewModel.isSelected(.node(nodeID)) {
          viewModel.select(.node(nodeID))
        }
        _ = viewModel.nudgeSelection(by: CGSize(width: 10, height: 0))
      }
      .modifier(
        PolicyCanvasNodePasteAccessibilityAction(viewModel: viewModel, canPaste: canPaste)
      )
      .accessibilityActions {
        ForEach(connectTargets) { target in
          Button("Connect to \(target.displayName)") {
            _ = viewModel.accessibilityConnect(fromNodeID: nodeID, to: target.endpoint)
          }
        }
      }
  }
}

/// Per-node Paste action, gated on a non-empty clipboard. Built as a
/// separate ViewModifier so the action is only stamped when there is
/// something to paste — VO users do not see a "Paste" rotor entry that
/// does nothing.
private struct PolicyCanvasNodePasteAccessibilityAction: ViewModifier {
  let viewModel: PolicyCanvasViewModel
  let canPaste: Bool

  func body(content: Content) -> some View {
    if canPaste {
      content.accessibilityAction(named: Text("Paste")) {
        _ = viewModel.pasteFromClipboard()
      }
    } else {
      content
    }
  }
}
