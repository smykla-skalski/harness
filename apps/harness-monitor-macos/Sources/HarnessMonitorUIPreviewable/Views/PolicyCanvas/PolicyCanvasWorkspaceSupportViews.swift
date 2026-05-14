import SwiftUI

struct PolicyCanvasEdgeLabelMetrics {
  let horizontalPadding: CGFloat
  let minWidth: CGFloat
  let height: CGFloat

  init(fontScale: CGFloat) {
    let scale = min(SessionWindowFontScale.metricsScale(for: fontScale), 1.45)
    horizontalPadding = (12 * scale).rounded(.up)
    minWidth = (88 * scale).rounded(.up)
    height = max(
      PolicyCanvasLayout.edgeLabelHeight,
      (PolicyCanvasLayout.edgeLabelHeight * scale).rounded(.up)
    )
  }
}

struct PolicyCanvasEdgeShape: Shape {
  let route: PolicyCanvasEdgeRoute

  func path(in rect: CGRect) -> Path {
    var path = Path()
    guard let firstPoint = route.points.first else {
      return path
    }
    path.move(to: firstPoint)
    for point in route.points.dropFirst() {
      path.addLine(to: point)
    }
    return path
  }
}

struct PolicyCanvasGroupRegion: View {
  let group: PolicyCanvasGroup
  let isSelected: Bool
  let isHighlighted: Bool

  var body: some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: PolicyCanvasLayout.groupCornerRadius)
        .fill(group.tone.color.opacity(isHighlighted ? 0.24 : 0.16))
        .overlay {
          RoundedRectangle(cornerRadius: PolicyCanvasLayout.groupCornerRadius)
            .stroke(
              group.tone.color.opacity(isSelected || isHighlighted ? 0.88 : 0.42),
              style: StrokeStyle(lineWidth: isSelected ? 1.6 : 1, dash: [6, 5])
            )
        }

      Text(group.title)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(group.tone.color.opacity(0.95))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.34), in: Capsule())
        .padding(10)
    }
    .frame(width: group.frame.width, height: group.frame.height)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(group.title)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasGroup(group.id))
  }
}
