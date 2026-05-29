import SwiftUI

struct PolicyCanvasMinimapOverlay: View {
  let snapshot: PolicyCanvasMinimapSnapshot
  let onViewportDrag: @MainActor (CGPoint) -> Void

  @State private var dragStartViewportOrigin: CGPoint?

  var body: some View {
    GeometryReader { proxy in
      let projection = policyCanvasMinimapProjection(
        snapshot: snapshot,
        minimapSize: proxy.size
      )
      let projectedGroups = snapshot.groupFrames.map(projection.rect(forCanvasRect:))
      let projectedNodes = snapshot.nodeFrames.map(projection.rect(forCanvasRect:))
      let projectedViewport = projection.rect(forCanvasRect: snapshot.viewportRect)
      ZStack(alignment: .topLeading) {
        Canvas { context, _ in
          if !projectedGroups.isEmpty {
            var groupPath = Path()
            for frame in projectedGroups {
              groupPath.addRoundedRect(
                in: frame,
                cornerSize: CGSize(width: 6, height: 6)
              )
            }
            context.stroke(
              groupPath,
              with: .color(PolicyCanvasVisualStyle.border.opacity(0.55)),
              lineWidth: 1
            )
          }

          if !projectedNodes.isEmpty {
            var nodePath = Path()
            for frame in projectedNodes {
              nodePath.addRoundedRect(
                in: frame,
                cornerSize: CGSize(width: 4, height: 4)
              )
            }
            context.fill(
              nodePath,
              with: .color(PolicyCanvasVisualStyle.secondaryText.opacity(0.28))
            )
          }
        }

        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(Color.accentColor.opacity(0.14))
          .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .stroke(Color.accentColor.opacity(0.95), lineWidth: 1.5)
          }
          .frame(
            width: max(18, projectedViewport.width),
            height: max(18, projectedViewport.height)
          )
          .position(
            x: projectedViewport.midX,
            y: projectedViewport.midY
          )
          .contentShape(Rectangle())
          .gesture(
            DragGesture(minimumDistance: 0)
              .onChanged { value in
                let dragStartOrigin: CGPoint
                if let current = dragStartViewportOrigin {
                  dragStartOrigin = current
                } else {
                  dragStartOrigin = snapshot.viewportRect.origin
                  dragStartViewportOrigin = dragStartOrigin
                }

                let translation = projection.canvasTranslation(
                  forMinimapTranslation: value.translation
                )
                onViewportDrag(
                  CGPoint(
                    x: dragStartOrigin.x + translation.width,
                    y: dragStartOrigin.y + translation.height
                  )
                )
              }
              .onEnded { _ in
                dragStartViewportOrigin = nil
              }
          )
          .accessibilityLabel("Canvas viewport")
          .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasMinimapViewport)
      }
    }
    .frame(width: 180, height: 140)
    .padding(8)
    .background(
      PolicyCanvasVisualStyle.panelBackground.opacity(0.96),
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(PolicyCanvasVisualStyle.border, lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Canvas minimap")
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasMinimap)
  }
}
