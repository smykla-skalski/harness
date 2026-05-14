import SwiftUI

struct PolicyCanvasViewport: View {
  let viewModel: PolicyCanvasViewModel
  let focusedComponent: AccessibilityFocusState<PolicyCanvasSelection?>.Binding
  /// View-only flag from the host. The host (`PolicyCanvasView`) auto-flips
  /// this on when a simulation is available and the user is on the
  /// simulation tab; the chrome toggle in the top bar lets the user hide
  /// the overlay even when both conditions hold. Simulation visibility is
  /// purely viewport state — never set `documentDirty` from this seam.
  var showSimulationOverlay: Bool = false
  @State private var magnifyStartZoom: CGFloat?

  var body: some View {
    GeometryReader { proxy in
      ScrollViewReader { scrollProxy in
        ScrollView([.horizontal, .vertical]) {
          ZStack(alignment: .topLeading) {
            PolicyCanvasDottedGrid(spacing: PolicyCanvasLayout.gridSize * viewModel.zoom)

            Color.clear
              .frame(width: 1, height: 1)
              .position(viewModel.initialViewportAnchorPoint)
              .id(PolicyCanvasLayout.initialViewportAnchorID)
              .accessibilityHidden(true)

            ZStack(alignment: .topLeading) {
              PolicyCanvasGroupLayer(viewModel: viewModel, focusedComponent: focusedComponent)
              PolicyCanvasEdgeLayer(viewModel: viewModel)
              PolicyCanvasRubberBandLayer(viewModel: viewModel)
              PolicyCanvasNodeLayer(viewModel: viewModel, focusedComponent: focusedComponent)
              if showSimulationOverlay {
                PolicyCanvasSimulationLayer(viewModel: viewModel)
              }
              PolicyCanvasEdgeLabelLayer(viewModel: viewModel, focusedComponent: focusedComponent)
            }
            .scaleEffect(viewModel.zoom, anchor: .topLeading)
            .coordinateSpace(.named(PolicyCanvasCoordinateSpaces.canvas))
          }
          .frame(
            width: max(proxy.size.width, viewModel.canvasContentSize.width * viewModel.zoom),
            height: max(proxy.size.height, viewModel.canvasContentSize.height * viewModel.zoom),
            alignment: .topLeading
          )
          .contentShape(Rectangle())
          .dropDestination(for: String.self) { payloads, location in
            viewModel.dropPalettePayloads(
              payloads,
              at: viewModel.canvasPoint(for: location)
            )
          }
          .onTapGesture {
            viewModel.select(nil)
          }
          .overlay {
            PolicyCanvasEmptyStatePlaceholder(viewModel: viewModel)
              .allowsHitTesting(false)
          }
        }
        .scrollIndicators(.visible)
        .background(Color(red: 0.03, green: 0.04, blue: 0.06))
        .clipShape(Rectangle())
        .overlay(alignment: .bottomLeading) {
          PolicyCanvasZoomControls(viewModel: viewModel)
            .padding(14)
        }
        .overlay(alignment: .bottomTrailing) {
          PolicyCanvasShortcutsDisclosure()
            .padding(14)
        }
        .simultaneousGesture(magnifyGesture)
        .onAppear {
          centerViewportIfNeeded(scrollProxy)
        }
        .onChange(of: viewModel.viewportCenteringGeneration, initial: false) {
          centerViewportIfNeeded(scrollProxy)
        }
      }
    }
    // P57: `.contain` is paired only with `.accessibilityIdentifier` here (no
    // parent label) so the rotor + children stay exposed without the
    // VoiceOver "stops on every child of a labelled element" footgun. Two
    // rotors live below: "Nodes" walks the visual focus order so VO users
    // can hop across the graph; "Edges" lists every wired connection.
    .accessibilityElement(children: .contain)
    .accessibilityRotor("Nodes") {
      // P25: rotor entries built lazily from the focus-order id list; we map
      // ids to labels per-iteration so the rotor content closure never
      // captures live node values across frames. Anchoring the rotor entry
      // on the node's identifier delegates ring focus to the
      // `.accessibilityFocused` modifier on the matching node card.
      ForEach(viewModel.accessibilityNodeFocusOrder(), id: \.self) { nodeID in
        if let node = viewModel.node(nodeID) {
          AccessibilityRotorEntry(
            viewModel.accessibilityLabel(for: node),
            id: nodeID
          )
        }
      }
    }
    .accessibilityRotor("Edges") {
      ForEach(viewModel.edges, id: \.id) { edge in
        AccessibilityRotorEntry(
          viewModel.accessibilityLabel(for: edge),
          id: edge.id
        )
      }
    }
    .accessibilityFrameMarker(HarnessMonitorAccessibility.policyCanvasViewport)
  }

  private func centerViewportIfNeeded(_ scrollProxy: ScrollViewProxy) {
    guard viewModel.consumeViewportCenteringRequest() else {
      return
    }
    Task { @MainActor in
      await Task.yield()
      scrollProxy.scrollTo(PolicyCanvasLayout.initialViewportAnchorID, anchor: .center)
    }
  }

  private var magnifyGesture: some Gesture {
    MagnifyGesture(minimumScaleDelta: 0.01)
      .onChanged { value in
        let baseZoom = magnifyStartZoom ?? viewModel.zoom
        if magnifyStartZoom == nil {
          magnifyStartZoom = baseZoom
        }
        viewModel.setZoom(baseZoom * value.magnification)
      }
      .onEnded { _ in
        magnifyStartZoom = nil
      }
  }
}

private struct PolicyCanvasDottedGrid: View {
  let spacing: CGFloat

  var body: some View {
    Canvas { context, size in
      let dot = Path(
        ellipseIn: CGRect(
          x: 0,
          y: 0,
          width: 1.5,
          height: 1.5
        )
      )
      let xValues = stride(from: CGFloat(0), through: size.width, by: max(8, spacing))
      let yValues = stride(from: CGFloat(0), through: size.height, by: max(8, spacing))
      for x in xValues {
        for y in yValues {
          context.translateBy(x: x, y: y)
          context.fill(dot, with: .color(.white.opacity(0.13)))
          context.translateBy(x: -x, y: -y)
        }
      }
    }
    .background(
      LinearGradient(
        colors: [
          Color(red: 0.06, green: 0.07, blue: 0.10),
          Color(red: 0.03, green: 0.04, blue: 0.06),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    )
  }
}

// `PolicyCanvasGroupLayer` + `PolicyCanvasGroupRegion` live in
// `PolicyCanvasGroupViews.swift`; `PolicyCanvasEdgeLayer`,
// `PolicyCanvasEdgeLabelLayer`, `PolicyCanvasEdgeLabelMetrics`, and
// `PolicyCanvasEdgeShape` live in `PolicyCanvasEdgeViews.swift`. Both
// extractions keep this file under the 420-line cap.
