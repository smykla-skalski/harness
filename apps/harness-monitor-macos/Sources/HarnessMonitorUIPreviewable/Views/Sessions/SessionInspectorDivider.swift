import SwiftUI

struct SessionInspectorDivider: View {
  @Binding var width: Double
  let minWidth: Double
  let maxWidth: Double
  @State private var dragStartWidth: Double?

  var body: some View {
    Rectangle()
      .fill(.separator)
      .frame(width: 1)
      .overlay(alignment: .center) {
        Color.clear
          .frame(width: 8)
          .contentShape(Rectangle())
          .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
              .onChanged { value in
                if dragStartWidth == nil { dragStartWidth = width }
                let delta = value.translation.width
                let next = (dragStartWidth ?? width) - delta
                width = max(minWidth, min(next, maxWidth))
              }
              .onEnded { _ in dragStartWidth = nil }
          )
      }
      .accessibilityHidden(true)
  }
}
