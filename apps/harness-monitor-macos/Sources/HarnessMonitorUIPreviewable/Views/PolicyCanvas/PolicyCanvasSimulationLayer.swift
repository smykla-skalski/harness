import SwiftUI

/// Renders per-node simulation outcomes on top of the node layer:
///   - `.allowed` → green checkmark badge top-right
///   - `.denied(reason)` → red X badge top-right; hover tooltip carries reason
///   - `.unreached` → 50% opacity dim overlay on the node body
///   - `.indeterminate` → no overlay (silence beats lying)
///
/// The map is read from the view model's `simulationOutcomeMap()` cache so
/// per-row lookups stay O(1) and don't re-walk decisions per frame. Hoisting
/// the map into a body-local `let` is load-bearing here — the same precedent
/// as the Wave 2E severity-map cache reader in `PolicyCanvasNodeLayer`.
///
/// This layer renders ABOVE `PolicyCanvasNodeLayer` in the workspace ZStack
/// so badges sit on top of nodes; the `.unreached` dim uses a translucent
/// overlay over the node's rendered footprint without touching the node
/// card view itself (3G owns the a11y framework, and 3M owns the node-card
/// tests — this layer stays out of those territories).
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
            .offset(x: node.position.x, y: node.position.y)
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
          .fill(Color.black.opacity(0.5))
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
    case .unreached, .indeterminate:
      return nil
    }
  }
}

/// Visual variant for the corner badge. Pulled into its own type so the
/// badge view stays free of the outcome enum's `.unreached`/`.indeterminate`
/// branches that don't render a badge — keeps the view body a single switch
/// over rendered states.
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
      return .green
    case .denied:
      return .red
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
          .background(.black.opacity(0.68), in: Circle())
          .overlay {
            Circle()
              .stroke(kind.accentColor.opacity(0.85), lineWidth: 1)
          }
          .offset(x: 8, y: -8)
          .help(kind.reason ?? kind.verdictLabel)
          .accessibilityLabel(accessibilityLabel)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.policyCanvasSimulationBadge(node.id)
          )
      }
      Spacer()
    }
  }

  /// Read by VoiceOver when the rotor lands on the badge. Includes the node
  /// title so the user knows which component carries the verdict without
  /// chasing context, and the reason code when present so a deny isn't a
  /// black-box "denied".
  private var accessibilityLabel: String {
    let base = "Node \(node.title): \(kind.verdictLabel)"
    if let reason = kind.reason, !reason.isEmpty {
      return "\(base) - \(reason)"
    }
    return base
  }
}
