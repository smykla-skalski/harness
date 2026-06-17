import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

struct PolicyCanvasEdgeLabelLayer: View {
  let viewModel: PolicyCanvasViewModel
  let focusedComponent: AccessibilityFocusState<PolicyCanvasSelection?>.Binding
  /// Shared with `PolicyCanvasEdgeLayer` via the viewport parent so both
  /// layers iterate the same hoisted array (one `@Observable` read instead
  /// of one read per layer).
  let edges: [PolicyCanvasEdge]
  let routes: [String: PolicyCanvasEdgeRoute]
  let labelPositions: [String: CGPoint]
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.colorScheme)
  private var colorScheme

  var body: some View {
    let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: fontScale)
    ZStack(alignment: .topLeading) {
      ForEach(edges) { edge in
        if !edge.label.isEmpty, let route = routes[edge.id] {
          let labelPosition = labelPositions[edge.id] ?? route.labelPosition
          let labelSize = metrics.size(for: edge.label)
          Button {
            viewModel.select(.edge(edge.id))
          } label: {
            Text(edge.label)
              .scaledFont(.caption2.weight(.semibold))
              .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
              .lineLimit(1)
              .truncationMode(.middle)
              .padding(.horizontal, metrics.horizontalPadding)
              .frame(
                width: labelSize.width,
                height: labelSize.height
              )
              .contentShape(Rectangle())
              .background(
                PolicyCanvasVisualStyle.edgeLabelBackground(edge.kind, colorScheme: colorScheme),
                in: RoundedRectangle(
                  cornerRadius: PolicyCanvasVisualStyle.edgeLabelCornerRadius, style: .continuous)
              )
              .overlay {
                RoundedRectangle(
                  cornerRadius: PolicyCanvasVisualStyle.edgeLabelCornerRadius, style: .continuous
                )
                .stroke(PolicyCanvasVisualStyle.subtleBorder, lineWidth: 1)
              }
          }
          .harnessPlainButtonStyle()
          .position(labelPosition)
          // Stroke owns the rotor entry per edge; the label stays clickable
          // for sighted users but the a11y tree only carries it once.
          .accessibilityHidden(true)
          .contextMenu {
            Button("Delete edge", role: .destructive) {
              viewModel.deleteEdge(edge.id)
            }
          }
        }
      }
    }
  }
}
