import SwiftUI

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
        .foregroundStyle(kind.accentColor)
        .frame(width: 22, height: 22)
        .background(kind.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))

      Text(kind.title)
        .scaledFont(.callout.weight(.semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
    }
    .padding(.horizontal, metrics.chipHorizontalPadding)
    .padding(.vertical, metrics.chipVerticalPadding)
    .background(Color(red: 0.08, green: 0.09, blue: 0.13).opacity(0.94), in: Capsule())
    .overlay {
      Capsule()
        .stroke(kind.accentColor.opacity(0.55), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 4)
  }
}
