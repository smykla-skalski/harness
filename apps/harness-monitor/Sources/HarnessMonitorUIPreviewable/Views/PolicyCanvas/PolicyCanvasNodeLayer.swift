import HarnessMonitorPolicyCanvasAlgorithms
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
  let nodeAccessibilityValuesByID: [String: String]
  let connectTargetsByNodeID: [String: [PolicyCanvasAccessibilityConnectTarget]]
  let nodeValidationIssueMessagesByID: [String: String]
  let portVisibility: PolicyCanvasPortVisibilityMap
  let portMarkerLayout: PolicyCanvasPortMarkerLayout
  let observationStore: PolicyCanvasViewportObservationStore
  let viewportIdentity: String?
  let openEditor: @MainActor (PolicyCanvasEditSheet) -> Void
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
    let hasClipboard = viewModel.clipboard != nil
    let cullRect = policyCanvasViewportCullRect(
      observationStore: observationStore,
      viewportIdentity: viewportIdentity
    )
    // Iterate in visual focus order (top-to-bottom, then left-to-right) rather
    // than document/storage order: SwiftUI walks Tab/Shift+Tab focus in
    // view-declaration order, so emitting the cards in screen order makes the
    // keyboard ring follow what the user sees. Node identity is keyed by id, so
    // a reorder (e.g. mid-drag as positions change) preserves per-card state.
    ForEach(viewModel.nodesInFocusOrder) { node in
      if policyCanvasNodeIsVisible(node, in: cullRect) {
      PolicyCanvasNodeCard(
        node: node,
        isSelected: viewModel.isSelected(.node(node.id)),
        isFocused: focusedNodeID == node.id || accessibilityFocusedNodeID == node.id,
        severity: severityMap[node.id],
        viewModel: viewModel,
        accessibilityValue: nodeAccessibilityValuesByID[node.id] ?? "",
        validationIssueMessages: nodeValidationIssueMessagesByID[node.id],
        connectTargets: connectTargetsByNodeID[node.id] ?? [],
        hasClipboard: hasClipboard,
        portVisibility: portVisibility,
        portMarkerLayout: portMarkerLayout,
        openEditor: openEditor
      )
      .position(
        x: node.position.x + PolicyCanvasLayout.nodeSize.width / 2,
        y: node.position.y + PolicyCanvasLayout.nodeSize.height / 2
      )
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
      .onTapGesture(count: 2) {
        viewModel.select(.node(node.id))
        focusedNodeID = node.id
        openEditor(.node(node.id))
      }
      .contextMenu {
        Button("Edit") {
          viewModel.select(.node(node.id))
          openEditor(.node(node.id))
        }
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
}

struct PolicyCanvasNodeCard: View {
  let node: PolicyCanvasNode
  let isSelected: Bool
  let isFocused: Bool
  let severity: PolicyCanvasIssueSeverity?
  let viewModel: PolicyCanvasViewModel
  let accessibilityValue: String
  let validationIssueMessages: String?
  let connectTargets: [PolicyCanvasAccessibilityConnectTarget]
  let hasClipboard: Bool
  let portVisibility: PolicyCanvasPortVisibilityMap
  let portMarkerLayout: PolicyCanvasPortMarkerLayout
  let openEditor: @MainActor (PolicyCanvasEditSheet) -> Void
  /// P19 reduce-motion handle for the P18 selection-mark transition. Pulled
  /// from the environment so the animation gating uses the same root-seeded
  /// bit the rest of the canvas reads. Canvas-scoped override is optional
  /// with system fallback; see `PolicyCanvasMotion`.
  @Environment(\.policyCanvasReducedMotion)
  private var canvasReducedMotion
  @Environment(\.accessibilityReduceMotion)
  private var systemReduceMotion
  @Environment(\.colorScheme)
  private var colorScheme
  @State private var isHovering = false

  private var reducedMotion: Bool {
    canvasReducedMotion ?? systemReduceMotion
  }

  private var borderLineWidth: CGFloat {
    severity == nil ? (isSelected ? 5.0 : 1.0) : 1.6
  }

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 8)
        .fill(PolicyCanvasVisualStyle.elevatedSurface.opacity(colorScheme == .dark ? 0.96 : 0.98))
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
        .overlay(alignment: .leading) {
          RoundedRectangle(cornerRadius: 1.5)
            .fill(node.kind.accentColor.opacity(isSelected ? 0.74 : 0.34))
            .frame(width: 3)
            .padding(.vertical, 8)
        }

      HStack(alignment: .top, spacing: 10) {
        Image(systemName: node.kind.symbolName)
          .scaledFont(.system(size: 16, weight: .semibold))
          .foregroundStyle(node.kind.accentColor.opacity(0.86))
          .frame(width: 24, height: 24)
          .background(
            node.kind.accentColor.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 6)
          )

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
            .foregroundStyle(PolicyCanvasVisualStyle.primaryText)
            .lineLimit(2)
            .truncationMode(.middle)
            .minimumScaleFactor(0.7)
            .allowsTightening(true)

          Text(node.subtitle)
            .scaledFont(.caption)
            // P29 contrast bump: 0.62 -> 0.78 puts the subtitle above the
            // ~5.5:1 AA threshold on the node's `#191F29` surface (was ~4:1).
            .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
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
        viewModel: viewModel,
        nodeIsActive: isSelected || isFocused || isHovering,
        visibleSides: portVisibility,
        markerLayout: portMarkerLayout
      )

      PolicyCanvasPortColumn(
        node: node,
        ports: node.outputPorts,
        alignment: .trailing,
        viewModel: viewModel,
        nodeIsActive: isSelected || isFocused || isHovering,
        visibleSides: portVisibility,
        markerLayout: portMarkerLayout
      )

      PolicyCanvasPortColumn(
        node: node,
        ports: node.inputPorts,
        alignment: .top,
        viewModel: viewModel,
        nodeIsActive: isSelected || isFocused || isHovering,
        visibleSides: portVisibility,
        markerLayout: portMarkerLayout,
        isAuxiliary: true
      )

      PolicyCanvasPortColumn(
        node: node,
        ports: node.outputPorts,
        alignment: .bottom,
        viewModel: viewModel,
        nodeIsActive: isSelected || isFocused || isHovering,
        visibleSides: portVisibility,
        markerLayout: portMarkerLayout,
        isAuxiliary: true
      )

      // Routed ports can legally use any side. Keep the primary columns on the
      // normal flow sides above, and add auxiliary columns for the non-default
      // sides so back-edges and side-entering branches still land on a dot.
      PolicyCanvasPortColumn(
        node: node,
        ports: node.inputPorts,
        alignment: .bottom,
        viewModel: viewModel,
        nodeIsActive: isSelected || isFocused || isHovering,
        visibleSides: portVisibility,
        markerLayout: portMarkerLayout,
        isAuxiliary: true
      )

      PolicyCanvasPortColumn(
        node: node,
        ports: node.inputPorts,
        alignment: .trailing,
        viewModel: viewModel,
        nodeIsActive: isSelected || isFocused || isHovering,
        visibleSides: portVisibility,
        markerLayout: portMarkerLayout,
        isAuxiliary: true
      )

      PolicyCanvasPortColumn(
        node: node,
        ports: node.outputPorts,
        alignment: .top,
        viewModel: viewModel,
        nodeIsActive: isSelected || isFocused || isHovering,
        visibleSides: portVisibility,
        markerLayout: portMarkerLayout,
        isAuxiliary: true
      )

      PolicyCanvasPortColumn(
        node: node,
        ports: node.outputPorts,
        alignment: .leading,
        viewModel: viewModel,
        nodeIsActive: isSelected || isFocused || isHovering,
        visibleSides: portVisibility,
        markerLayout: portMarkerLayout,
        isAuxiliary: true
      )

      if let severity {
        severityBadge(for: severity)
      }
    }
    .frame(width: PolicyCanvasLayout.nodeSize.width, height: PolicyCanvasLayout.nodeSize.height)
    .onHover { isHovering = $0 }
    // P57: `.ignore` (paired with composed label/value) avoids the
    // contradictory-rotor case where `.contain` would expose children
    // individually while a parent label was set. Children carry their own
    // a11y where needed (severity badge is .accessibilityHidden, port views
    // own their labels).
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(viewModel.accessibilityLabel(for: node))
    .accessibilityValue(nodeAccessibilityValue)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasNode(node.id))
    .modifier(
      PolicyCanvasNodeAccessibilityActions(
        viewModel: viewModel,
        nodeID: node.id,
        connectTargets: connectTargets,
        canPaste: hasClipboard,
        openEditor: { openEditor(.node(node.id)) }
      )
    )
  }

  private var strokeColor: Color {
    PolicyCanvasVisualStyle.nodeStroke(
      node.kind,
      colorScheme: colorScheme,
      isSelected: isSelected,
      severity: severity,
      isFocused: isFocused
    )
  }

  private var nodeAccessibilityValue: String {
    let base = accessibilityValue
    guard let severity else {
      return base
    }
    let issues = validationIssueMessages ?? ""
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
          .background(PolicyCanvasVisualStyle.canvasBackground.opacity(0.88), in: Circle())
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
