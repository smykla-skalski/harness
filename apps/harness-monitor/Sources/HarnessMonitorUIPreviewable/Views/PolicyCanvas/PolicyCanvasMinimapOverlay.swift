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
  @State private var isHoveringMinimap = false
  @State private var isDraggingViewport = false
  @State private var activeMinimapCursor: NSCursor?

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
                if !isDraggingViewport {
                  isDraggingViewport = true
                  refreshMinimapCursor()
                }
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
              .onEnded { value in
                // A click (no real drag) recenters the viewport on the policy
                // content, wherever in the minimap it landed. A longer drag has
                // already panned through onChanged and keeps its position.
                if policyCanvasMinimapGestureIsClick(translation: value.translation) {
                  onViewportDrag(snapshot.viewportOriginCenteredOnContent)
                }
                dragStartViewportOrigin = nil
                isDraggingViewport = false
                refreshMinimapCursor()
              }
          )
          .accessibilityLabel("Canvas viewport")
          .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasMinimapViewport)
      }
      .contentShape(Rectangle())
      .onHover { hovering in
        isHoveringMinimap = hovering
        refreshMinimapCursor()
      }
      .onDisappear {
        if activeMinimapCursor != nil {
          NSCursor.pop()
          activeMinimapCursor = nil
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

  // Hover shows the pointing hand; an active grab shows the closed hand. The
  // cursor has to be pushed imperatively because the native .pointerStyle only
  // resolves on hover - AppKit suppresses cursor-rect updates while the mouse
  // button is held, so it cannot switch to the closed hand mid-drag.
  private func refreshMinimapCursor() {
    let desired: NSCursor? =
      isDraggingViewport ? .closedHand : (isHoveringMinimap ? .pointingHand : nil)
    guard desired !== activeMinimapCursor else { return }
    if activeMinimapCursor != nil {
      NSCursor.pop()
    }
    desired?.push()
    activeMinimapCursor = desired
  }
}
