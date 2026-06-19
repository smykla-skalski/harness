// Companion to PolicyCanvasWorkspaceViews+ScrollCoordinator.swift.
// Hosts PolicyCanvasViewportHostedRoot and the policyCanvasDocumentLayer
// view modifier used by its content layers.
import AppKit
import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

struct PolicyCanvasViewportHostedRoot: View {
  let state: PolicyCanvasViewportHostedState

  var body: some View {
    let snapshot = state.snapshot
    let workspaceLayout = state.workspaceLayout
    ZStack(alignment: .topLeading) {
      PolicyCanvasBackgroundSurface()
        .frame(
          width: workspaceLayout.workspaceSize.width,
          height: workspaceLayout.workspaceSize.height,
          alignment: .topLeading
        )
        .contentShape(Rectangle())
        .onTapGesture {
          snapshot.viewModel.select(nil)
        }
      ZStack(alignment: .topLeading) {
        Group {
          if snapshot.hasRenderableRouteOutput {
            PolicyCanvasGroupLayer(
              viewModel: snapshot.viewModel,
              focusedComponent: snapshot.focusedComponent,
              openEditor: snapshot.openEditor
            )
            .policyCanvasDocumentLayer(size: snapshot.contentSize)
            PolicyCanvasEdgeLayer(
              viewModel: snapshot.viewModel,
              focusedComponent: snapshot.focusedComponent,
              edges: snapshot.edges,
              routes: snapshot.routes,
              labelPositions: snapshot.labelPositions,
              contentSize: snapshot.contentSize,
              accessibilityLabelsByEdgeID: snapshot.accessibilityLabelsByEdgeID,
              openEditor: snapshot.openEditor
            )
            .policyCanvasDocumentLayer(size: snapshot.contentSize)
            PolicyCanvasMarqueeSelectionLayer(
              marqueeSelection: snapshot.viewModel.marqueeSelection
            )
            .policyCanvasDocumentLayer(size: snapshot.contentSize)
            PolicyCanvasRubberBandLayer(viewModel: snapshot.viewModel)
              .policyCanvasDocumentLayer(size: snapshot.contentSize)
            PolicyCanvasNodeLayer(
              viewModel: snapshot.viewModel,
              focusedComponent: snapshot.focusedComponent,
              nodeAccessibilityValuesByID: snapshot.nodeAccessibilityValuesByID,
              connectTargetsByNodeID: snapshot.connectTargetsByNodeID,
              nodeValidationIssueMessagesByID: snapshot.nodeValidationIssueMessagesByID,
              portVisibility: snapshot.portVisibility,
              portMarkerLayout: snapshot.portMarkerLayout,
              openEditor: snapshot.openEditor
            )
            .policyCanvasDocumentLayer(size: snapshot.contentSize)
            if snapshot.showSimulationOverlay {
              PolicyCanvasSimulationLayer(viewModel: snapshot.viewModel)
                .policyCanvasDocumentLayer(size: snapshot.contentSize)
            }
            PolicyCanvasEdgeLabelLayer(
              viewModel: snapshot.viewModel,
              focusedComponent: snapshot.focusedComponent,
              edges: snapshot.edges,
              routes: snapshot.routes,
              labelPositions: snapshot.labelPositions
            )
            .policyCanvasDocumentLayer(size: snapshot.contentSize)
            // Mounted unconditionally and reading the report live in their own
            // bodies, so a variant switch or overlay toggle re-renders them. A
            // parent `if let` here would capture a stale report inside the hosted
            // canvas. Both draw nothing when the lab overlay is off.
            PolicyCanvasQualityOverlayLayer(viewModel: snapshot.viewModel)
              .policyCanvasDocumentLayer(size: snapshot.contentSize)
            PolicyCanvasQualityHoverLayer(viewModel: snapshot.viewModel)
              .policyCanvasDocumentLayer(size: snapshot.contentSize)
          }
        }
        .policyCanvasDocumentLayer(size: snapshot.contentSize)
      }
      .policyCanvasDocumentLayer(size: snapshot.contentSize)
      .offset(x: workspaceLayout.contentOrigin.x, y: workspaceLayout.contentOrigin.y)
    }
    .policyCanvasResolvedThemeScope(snapshot.resolvedCanvasColorScheme)
    .frame(
      width: workspaceLayout.workspaceSize.width,
      height: workspaceLayout.workspaceSize.height,
      alignment: .topLeading
    )
    .coordinateSpace(.named(PolicyCanvasCoordinateSpaces.canvas))
    .contentShape(Rectangle())
    .dropDestination(for: String.self) { payloads, location in
      snapshot.viewModel.dropPalettePayloads(
        payloads,
        at: workspaceLayout.contentPoint(forWorkspacePoint: location)
      )
    }
    .accessibilityElement(children: .contain)
    .accessibilityRotor("Nodes") {
      ForEach(snapshot.accessibilityNodeEntries) { entry in
        AccessibilityRotorEntry(entry.label, id: entry.id)
      }
    }
    .accessibilityRotor("Edges") {
      ForEach(snapshot.accessibilityEdgeEntries) { entry in
        AccessibilityRotorEntry(entry.label, id: entry.id)
      }
    }
  }
}

extension View {
  func policyCanvasDocumentLayer(size: CGSize) -> some View {
    frame(width: size.width, height: size.height, alignment: .topLeading)
  }
}
