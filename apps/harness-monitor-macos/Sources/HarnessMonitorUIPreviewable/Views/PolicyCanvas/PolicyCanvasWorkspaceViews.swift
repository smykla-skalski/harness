import SwiftUI

// Minimum platform target for the trackpad and gesture APIs below
// (`MagnifyGesture`, `.scrollIndicators(.visible)`, `.dropDestination(for:)`):
// macOS 14 / iOS 17. The Monitor app targets macOS 26, so the gestures
// compile unconditionally; if the deployment target ever drops below 14,
// these surfaces need an availability gate or AppKit fallback.
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
  @State private var zoomFocusDispatcher = PolicyCanvasZoomFocusDispatcher()
  @State private var zoomFocus: PolicyCanvasZoomFocus?
  @Environment(\.scenePhase)
  private var scenePhase

  var body: some View {
    GeometryReader { proxy in
      ScrollViewReader { scrollProxy in
        ScrollView([.horizontal, .vertical]) {
          // Hoist the edges array and the bulk port-anchor map once per
          // viewport body run, then pass both into the edge layers. Before
          // this hoist, `PolicyCanvasEdgeLayer` and `PolicyCanvasEdgeLabelLayer`
          // each rebuilt the same dictionary, doubling the cost per render
          // cycle. Each layer's body also read `viewModel.edges` twice via
          // the `@Observable` accessor.
          let edges = viewModel.edges
          let portAnchors = viewModel.portAnchors(for: edges)
          ZStack(alignment: .topLeading) {
            PolicyCanvasDottedGrid(spacing: PolicyCanvasLayout.gridSize * viewModel.zoom)

            Color.clear
              .frame(width: 1, height: 1)
              .position(viewModel.initialViewportAnchorPoint)
              .id(PolicyCanvasLayout.initialViewportAnchorID)
              .accessibilityHidden(true)

            ZStack(alignment: .topLeading) {
              PolicyCanvasGroupLayer(viewModel: viewModel, focusedComponent: focusedComponent)
              PolicyCanvasEdgeLayer(
                viewModel: viewModel,
                edges: edges,
                portAnchors: portAnchors
              )
              PolicyCanvasRubberBandLayer(viewModel: viewModel)
              PolicyCanvasNodeLayer(viewModel: viewModel, focusedComponent: focusedComponent)
              if showSimulationOverlay {
                PolicyCanvasSimulationLayer(viewModel: viewModel)
              }
              PolicyCanvasEdgeLabelLayer(
                viewModel: viewModel,
                focusedComponent: focusedComponent,
                edges: edges,
                portAnchors: portAnchors
              )
            }
            // Pinch zoom uses the unit-space anchor captured on pinch start so
            // the content under the user's fingers stays under their fingers
            // as the scale changes. Chrome buttons (Cmd-+, Cmd-=, Cmd--,
            // Cmd-0) leave `pinchAnchorUnit` nil and fall through to the
            // canvas top-leading origin, matching the prior visual behavior.
            .scaleEffect(viewModel.zoom, anchor: viewModel.pinchAnchorUnit ?? .topLeading)
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
        // ScrollView pan respects the user's natural-scroll setting because
        // it routes through AppKit's standard scroll machinery (which reads
        // `NSEvent.isDirectionInvertedFromDevice`). No app-side direction
        // adjustment needed.
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
        .simultaneousGesture(magnifyGesture(in: proxy.size))
        .onAppear {
          centerViewportIfNeeded(scrollProxy)
          bindZoomFocusDispatcher()
        }
        .onChange(of: viewModel.viewportCenteringGeneration, initial: false) {
          centerViewportIfNeeded(scrollProxy)
        }
        .onChange(of: scenePhase) { _, newPhase in
          // When the scene leaves .active mid-pinch (Cmd-Tab, Mission
          // Control, modal sheet, window minimize), MagnifyGesture's
          // .onEnded does not always fire — `magnifyStartZoom` would
          // otherwise stay non-nil and the next pinch would compute its
          // baseline against a stale value. Clear the in-flight gesture
          // state on every transition off .active.
          if newPhase != .active {
            magnifyStartZoom = nil
            viewModel.clearPinchAnchor()
          }
        }
        // Publish the zoom-focus dispatcher into the scene's FocusedValues so
        // a scene-level CommandGroup can route View-menu items and keyboard
        // chords (Cmd-+, Cmd-=, Cmd-0) at the live canvas. Identity-based
        // equality on the dispatcher keeps this from re-publishing on every
        // viewport body run.
        .focusedSceneValue(\.harnessPolicyCanvasZoomFocus, zoomFocus)
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

  /// Wire the in-viewport closures to the dispatcher and publish the focus
  /// value. Runs once on appear — chrome buttons still mutate the same view
  /// model methods directly, so a transient nil dispatcher binding is not
  /// observable from the UI.
  private func bindZoomFocusDispatcher() {
    zoomFocusDispatcher.zoomIn = { @MainActor [viewModel] in
      viewModel.clearPinchAnchor()
      viewModel.zoomIn()
    }
    zoomFocusDispatcher.zoomOut = { @MainActor [viewModel] in
      viewModel.clearPinchAnchor()
      viewModel.zoomOut()
    }
    zoomFocusDispatcher.resetZoom = { @MainActor [viewModel] in
      viewModel.clearPinchAnchor()
      viewModel.resetZoom()
    }
    if zoomFocus == nil {
      zoomFocus = PolicyCanvasZoomFocus(dispatcher: zoomFocusDispatcher)
    }
  }

  /// Trackpad pinch gesture. `MagnifyGesture.Value.startAnchor` carries the
  /// focal point as a unit-space `UnitPoint` over the gesture view's bounds,
  /// which matches what `.scaleEffect(_:anchor:)` expects. Routing the same
  /// `UnitPoint` into the view-model's `pinchAnchorUnit` keeps the content
  /// under the user's fingers stationary in screen space across the pinch.
  ///
  /// `magnifyStartZoom` is captured on first `.onChanged` (the value is the
  /// gesture's baseline zoom, not the running scale), so the per-tick math
  /// is `baseZoom * value.magnification`. `value.magnification` is 1.0 at
  /// pinch start and varies from there.
  private func magnifyGesture(in viewportSize: CGSize) -> some Gesture {
    MagnifyGesture(minimumScaleDelta: 0.01)
      .onChanged { value in
        let baseZoom = magnifyStartZoom ?? viewModel.zoom
        if magnifyStartZoom == nil {
          magnifyStartZoom = baseZoom
        }
        viewModel.setZoom(baseZoom * value.magnification, anchor: value.startAnchor)
      }
      .onEnded { _ in
        magnifyStartZoom = nil
        // Drop the anchor at end-of-gesture so subsequent chrome-button
        // zooms render from the canvas top-leading origin (matching the
        // visual contract of Cmd-+ / Cmd-= / Cmd-- / Cmd-0). The viewport
        // size is captured here only as a future hook — anchors are unit
        // space, so the dimension is not needed for the clear path.
        _ = viewportSize
        viewModel.clearPinchAnchor()
      }
  }
}

// `PolicyCanvasDottedGrid` lives in `PolicyCanvasGridLayers.swift`;
// `PolicyCanvasGroupLayer` + `PolicyCanvasGroupRegion` in
// `PolicyCanvasGroupViews.swift`; `PolicyCanvasEdgeLayer`,
// `PolicyCanvasEdgeLabelLayer`, `PolicyCanvasEdgeLabelMetrics`, and
// `PolicyCanvasEdgeShape` in `PolicyCanvasEdgeLayers.swift`. All extractions
// keep this file under the 420-line cap.
