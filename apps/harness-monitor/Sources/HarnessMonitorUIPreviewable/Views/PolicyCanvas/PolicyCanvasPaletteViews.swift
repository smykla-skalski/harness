import SwiftUI
import HarnessMonitorPolicyCanvasAlgorithms

/// Ghost chip rendered under the cursor while the user drags a palette item.
/// Mirrors the kind's accent color and icon so the user has a positive system
/// image of what the drop will create. Vanishes automatically when the drag
/// ends (handled by `.draggable(preview:)`).
struct PolicyCanvasPaletteDragChip: View {
  let kind: PolicyCanvasNodeKind
  let metrics: PolicyCanvasToolRailMetrics

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: kind.symbolName)
        .scaledFont(.system(size: max(14, metrics.iconSize - 1), weight: .semibold))
        .foregroundStyle(kind.accentColor.opacity(0.86))
        .frame(width: 22, height: 22)
        .background(kind.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))

      Text(kind.title)
        .scaledFont(.callout.weight(.semibold))
        .foregroundStyle(PolicyCanvasVisualStyle.primaryText)
        .lineLimit(1)
    }
    .padding(.horizontal, metrics.chipHorizontalPadding)
    .padding(.vertical, metrics.chipVerticalPadding)
    .background(
      PolicyCanvasVisualStyle.elevatedSurface.opacity(0.96),
      in: RoundedRectangle(cornerRadius: HarnessMonitorTheme.pillCornerRadius)
    )
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.pillCornerRadius)
        .stroke(kind.accentColor.opacity(0.32), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.22), radius: 6, x: 0, y: 3)
  }
}
