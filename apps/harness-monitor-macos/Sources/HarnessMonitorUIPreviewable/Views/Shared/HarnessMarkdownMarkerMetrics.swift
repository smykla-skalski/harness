import SwiftUI

struct HarnessMarkdownMarkerMetrics {
  let columnWidth: CGFloat
  let gap: CGFloat
  let firstLineHeight: CGFloat
  let firstLineMarkerYOffset: CGFloat
  let firstLineTextYOffset: CGFloat
  let listSymbolColumnWidth: CGFloat
  let chevronColumnWidth: CGFloat
  let chevronSize: CGFloat

  init(style: HarnessMarkdownResolvedRenderSettings) {
    let pointSize = style.typography.body.pointSize ?? 13
    columnWidth = max(style.spacing.listMarkerWidth, pointSize * 1.5)
    gap = style.spacing.listMarkerGap
    firstLineHeight = max(18, pointSize * 1.35)
    firstLineMarkerYOffset = -max(1, pointSize * 0.10)
    firstLineTextYOffset = max(0, (firstLineHeight - pointSize) / 2)
    listSymbolColumnWidth = max(style.spacing.listSymbolWidth, pointSize * 0.45)
    chevronColumnWidth = max(12, pointSize * 0.75)
    chevronSize = max(7, pointSize * 0.48)
  }
}

struct HarnessMarkdownPointerHoverModifier: ViewModifier {
  let color: Color
  @State private var isHovering = false

  func body(content: Content) -> some View {
    content
      .contentShape(Rectangle())
      .background {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(color.opacity(isHovering ? 0.12 : 0))
      }
      .onHover { hovering in
        guard isHovering != hovering else { return }
        isHovering = hovering
        if hovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }
      .onDisappear {
        guard isHovering else { return }
        NSCursor.pop()
        isHovering = false
      }
  }
}
