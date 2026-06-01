import AppKit
import SwiftUI

struct PolicyCanvasMinimapOverlay: View {
  let snapshot: PolicyCanvasMinimapSnapshot
  let onViewportDrag: @MainActor (CGPoint) -> Void

  @Environment(\.colorScheme)
  private var colorScheme
  @AppStorage(PolicyCanvasMinimapDefaults.isVisibleKey)
  private var minimapVisible = PolicyCanvasMinimapDefaults.isVisibleDefault
  @State private var dragStartViewportOrigin: CGPoint?

  var body: some View {
    GeometryReader { proxy in
      let projection = policyCanvasMinimapProjection(
        snapshot: snapshot,
        minimapSize: proxy.size
      )
      let projectedContentBounds = projection.rect(forCanvasRect: snapshot.worldBounds)
      let projectedGroups = snapshot.groupFrames.map(projection.rect(forCanvasRect:))
      let projectedNodes = snapshot.nodeFrames.map(projection.rect(forCanvasRect:))
      let projectedViewport = projection.rect(forCanvasRect: snapshot.viewportRect)
      let nodeStroke = PolicyCanvasVisualStyle.primaryText.opacity(
        colorScheme == .dark ? 0.72 : 0.58
      )
      ZStack(alignment: .topLeading) {
        Canvas { context, _ in
          let contentPlateFrame = projectedContentBounds.insetBy(dx: 0.5, dy: 0.5)
          var contentPlatePath = Path()
          contentPlatePath.addRoundedRect(
            in: contentPlateFrame,
            cornerSize: CGSize(width: 8, height: 8)
          )
          context.fill(
            contentPlatePath,
            with: .color(PolicyCanvasVisualStyle.canvasBackground)
          )
          context.stroke(
            contentPlatePath,
            with: .color(PolicyCanvasVisualStyle.subtleBorder),
            lineWidth: 1
          )

          if !projectedGroups.isEmpty {
            var groupFillPath = Path()
            var groupStrokePath = Path()
            for frame in projectedGroups {
              let groupFrame = frame.insetBy(dx: 0.5, dy: 0.5)
              groupFillPath.addRoundedRect(
                in: groupFrame,
                cornerSize: CGSize(width: 6, height: 6)
              )
              groupStrokePath.addRoundedRect(
                in: groupFrame,
                cornerSize: CGSize(width: 6, height: 6)
              )
            }
            context.fill(
              groupFillPath,
              with: .color(PolicyCanvasVisualStyle.secondaryText.opacity(0.14))
            )
            context.stroke(
              groupStrokePath,
              with: .color(PolicyCanvasVisualStyle.border.opacity(0.9)),
              lineWidth: 1
            )
          }

          if !projectedNodes.isEmpty {
            var nodePath = Path()
            for frame in projectedNodes {
              let nodeFrame = frame.insetBy(dx: 0.5, dy: 0.5)
              nodePath.addRoundedRect(
                in: nodeFrame,
                cornerSize: CGSize(width: 4, height: 4)
              )
            }
            context.fill(
              nodePath,
              with: .color(PolicyCanvasVisualStyle.minimapNodeFill(colorScheme))
            )
            context.stroke(
              nodePath,
              with: .color(nodeStroke.opacity(0.18)),
              lineWidth: 0.75
            )
          }
        }

        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(Color.accentColor.opacity(0.08))
          .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .stroke(Color.accentColor.opacity(0.95), lineWidth: 1.5)
              .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                  .stroke(PolicyCanvasVisualStyle.canvasBackground.opacity(0.9), lineWidth: 0.5)
              }
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
          .shadow(color: PolicyCanvasVisualStyle.rootBackground.opacity(0.22), radius: 2, y: 1)
          .gesture(
            DragGesture(minimumDistance: 0)
              .onChanged { value in
                let dragStartOrigin: CGPoint
                if let current = dragStartViewportOrigin {
                  dragStartOrigin = current
                } else {
                  dragStartOrigin = snapshot.viewportRect.origin
                  dragStartViewportOrigin = dragStartOrigin
                  // First change of this grab shows the closed-hand cursor. It
                  // survives the drag because AppKit suppresses cursor-rect
                  // updates while the button is held; the pointing hand from
                  // pointerStyle re-asserts once we pop on release.
                  NSCursor.closedHand.push()
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
                if dragStartViewportOrigin != nil {
                  NSCursor.pop()
                  // macOS only re-evaluates pointerStyle on the next mouse-moved
                  // event, so without setting the hover cursor now the popped-to
                  // arrow flashes until the pointer moves. Bridge that gap here;
                  // pointerStyle keeps the pointing hand on the next move.
                  NSCursor.pointingHand.set()
                }
                dragStartViewportOrigin = nil
              }
          )
          .pointerStyle(.link)
          .accessibilityLabel("Canvas viewport")
          .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasMinimapViewport)

        Button {
          onViewportDrag(snapshot.viewportOriginCenteredOnContent)
        } label: {
          Image(systemName: "dot.scope")
            .imageScale(.medium)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(PolicyCanvasMinimapCenterButtonStyle())
        .padding(6)
        .position(x: 20, y: proxy.size.height - 20)
        .pointerStyle(.link)
        .accessibilityLabel("Center canvas in minimap")
        .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasMinimapCenterButton)
      }
      .contentShape(Rectangle())
      .onDisappear {
        if dragStartViewportOrigin != nil {
          NSCursor.pop()
          dragStartViewportOrigin = nil
        }
      }
    }
    .frame(width: 180, height: 140)
    .padding(8)
    .background(
      PolicyCanvasVisualStyle.minimapBackground(colorScheme),
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(
          PolicyCanvasVisualStyle.floatingControlBorder(colorScheme),
          lineWidth: PolicyCanvasVisualStyle.floatingControlBorderLineWidth(colorScheme)
        )
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Canvas minimap")
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasMinimap)
    .contextMenu {
      Button {
        minimapVisible = false
      } label: {
        Label("Hide minimap", systemImage: "eye.slash")
      }
    }
  }
}

private struct PolicyCanvasMinimapCenterButtonStyle: ButtonStyle {
  @State private var isHovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(
        PolicyCanvasVisualStyle.activeTint.opacity(
          configuration.isPressed ? 1.0 : (isHovering ? 0.9 : 0.68)
        )
      )
      .scaleEffect(configuration.isPressed ? 0.88 : (isHovering ? 1.08 : 1))
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
      .animation(.easeOut(duration: 0.12), value: isHovering)
      .onHover { hovering in
        isHovering = hovering
      }
  }
}
