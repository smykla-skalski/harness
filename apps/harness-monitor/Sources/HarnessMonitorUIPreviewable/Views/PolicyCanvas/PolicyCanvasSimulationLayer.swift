import SwiftUI
import HarnessMonitorPolicyCanvasAlgorithms

/// Renders per-node simulation outcomes on top of the node layer:
///   - `.allowed` → green checkmark badge top-right
///   - `.denied(reason)` → red X badge top-right; hover tooltip carries reason
///   - `.unreached` → 50% opacity dim overlay on the node body
///   - absent from map → no overlay (no opinion / unclassifiable verdict)
///
/// The map is read from the view model's `simulationOutcomeMap()` cache so
/// per-row lookups stay O(1) and don't re-walk decisions per frame. Hoisting
/// the map into a body-local `let` is load-bearing here — the same precedent
/// as the Wave 2E severity-map cache reader in `PolicyCanvasNodeLayer`.
///
/// This layer renders ABOVE `PolicyCanvasNodeLayer` in the workspace ZStack
/// so badges sit on top of nodes; the `.unreached` dim uses a translucent
/// overlay over the node's rendered footprint without touching the node
/// card view itself (the parent node-card framework owns title a11y, and
/// the node-card tests own card rendering — this layer stays out of those
/// territories).
struct PolicyCanvasSimulationLayer: View {
  let viewModel: PolicyCanvasViewModel

  var body: some View {
    let outcomeMap = viewModel.simulationOutcomeMap()
    if outcomeMap.isEmpty {
      EmptyView()
    } else {
      ZStack(alignment: .topLeading) {
        ForEach(viewModel.nodes) { node in
          if let outcome = outcomeMap[node.id] {
            PolicyCanvasSimulationNodeOverlay(
              node: node,
              outcome: outcome
            )
            .position(
              x: node.position.x + PolicyCanvasLayout.nodeSize.width / 2,
              y: node.position.y + PolicyCanvasLayout.nodeSize.height / 2
            )
          }
        }
      }
      .allowsHitTesting(false)
    }
  }
}

/// Per-node overlay: dim rectangle for `.unreached` and a corner badge for
/// allowed/denied. Sized to the node frame so positions match the node card
/// layer underneath.
private struct PolicyCanvasSimulationNodeOverlay: View {
  let node: PolicyCanvasNode
  let outcome: PolicyCanvasSimulationOutcome

  var body: some View {
    ZStack {
      if case .unreached = outcome {
        RoundedRectangle(cornerRadius: 8)
          .fill(PolicyCanvasVisualStyle.canvasBackground.opacity(0.52))
          .accessibilityHidden(true)
      }
      if let badge = badgeKind {
        PolicyCanvasSimulationBadge(node: node, kind: badge)
      }
    }
    .frame(width: PolicyCanvasLayout.nodeSize.width, height: PolicyCanvasLayout.nodeSize.height)
  }

  private var badgeKind: PolicyCanvasSimulationBadgeKind? {
    switch outcome {
    case .allowed:
      return .allowed
    case .denied(let reason):
      return .denied(reason: reason)
    case .unreached:
      return nil
    }
  }
}

/// Visual variant for the corner badge. Pulled into its own type so the
/// badge view stays free of the outcome enum's `.unreached` branch — which
/// doesn't render a badge — and keeps the view body a single switch over
/// rendered states.
enum PolicyCanvasSimulationBadgeKind: Equatable {
  case allowed
  case denied(reason: String)

  var systemImage: String {
    switch self {
    case .allowed:
      return "checkmark.circle.fill"
    case .denied:
      return "xmark.circle.fill"
    }
  }

  /// Foreground tint. System green/red pass WCAG AA at this size on the
  /// canvas dark backdrop (`#080A0F`): green renders ~6.4:1, red renders
  /// ~5.5:1 — both well clear of the 4.5:1 threshold for small text.
  var accentColor: Color {
    switch self {
    case .allowed:
      return PolicyCanvasVisualStyle.readyTint
    case .denied:
      return PolicyCanvasVisualStyle.blockedTint
    }
  }

  var verdictLabel: String {
    switch self {
    case .allowed:
      return "allowed"
    case .denied:
      return "denied"
    }
  }

  var reason: String? {
    if case .denied(let reason) = self {
      return reason
    }
    return nil
  }

  /// VoiceOver label for the badge. Deliberately short and node-title free:
  /// the parent node card already exposes the node title via its own
  /// `accessibilityValue`, so including the title here would make VO read
  /// the node identity twice (once on the card, once on this sibling).
  /// The badge contributes only the verdict and the reason code (when
  /// present) so a deny isn't a black-box "denied".
  var accessibilityLabel: String {
    if let reason, !reason.isEmpty {
      return "\(verdictLabel): \(reason)"
    }
    return verdictLabel
  }
}

/// Top-right corner badge. Geometry mirrors the validation severity badge in
/// `PolicyCanvasNodeCard` so simulation and validation marks line up on the
/// same offset when both are present (validation wins the slot when both
/// fire — the validation panel is the authoritative surface for invalid
/// shape, simulation is for outcome on a valid shape). Today the two never
/// fire together because the daemon won't emit a successful simulation on
/// an invalid graph, but we still align the offset so a future change to
/// that contract doesn't visually fight.
private struct PolicyCanvasSimulationBadge: View {
  let node: PolicyCanvasNode
  let kind: PolicyCanvasSimulationBadgeKind

  var body: some View {
    VStack {
      HStack {
        Spacer()
        Image(systemName: kind.systemImage)
          .scaledFont(.system(size: 13, weight: .semibold))
          .foregroundStyle(kind.accentColor)
          .padding(4)
          .background(PolicyCanvasVisualStyle.canvasBackground.opacity(0.88), in: Circle())
          .overlay {
            Circle()
              .stroke(kind.accentColor.opacity(0.85), lineWidth: 1)
          }
          .offset(x: 8, y: -8)
          .help(kind.reason ?? kind.verdictLabel)
          .accessibilityLabel(kind.accessibilityLabel)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.policyCanvasSimulationBadge(node.id)
          )
      }
      Spacer()
    }
  }
}
