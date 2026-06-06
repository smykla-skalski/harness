import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

struct PolicyCanvasViewportOverlayModifier: ViewModifier {
  let viewModel: PolicyCanvasViewModel
  let observationStore: PolicyCanvasViewportObservationStore
  let storedPipelineStateRaw: String
  let suppressesSceneStorage: Bool
  let contentBounds: CGRect
  let minimapVisible: Bool
  let resolvedCanvasColorScheme: ColorScheme?
  let minimapCenteringModeOverride: PolicyCanvasMinimapCenteringMode?
  let showsEdgeLegend: Bool
  let requestViewportScroll: @MainActor (CGPoint) -> Void

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .topLeading) {
        if showsEdgeLegend {
          PolicyCanvasEdgeKindLegend()
            .policyCanvasResolvedThemeScope(resolvedCanvasColorScheme)
            .padding(14)
        }
      }
      .overlay(alignment: .bottomLeading) {
        PolicyCanvasZoomControls(viewModel: viewModel)
          .policyCanvasResolvedThemeScope(resolvedCanvasColorScheme)
          .padding(14)
      }
      .overlay(alignment: .bottomTrailing) {
        VStack(alignment: .trailing, spacing: 12) {
          if minimapVisible, !viewModel.isEmpty {
            PolicyCanvasMinimapViewportOverlay(
              viewModel: viewModel,
              observationStore: observationStore,
              viewportIdentity: viewModel.pipelineIdentity,
              storedPipelineStateRaw: storedPipelineStateRaw,
              suppressesSceneStorage: suppressesSceneStorage,
              contentBounds: contentBounds,
              minimapCenteringModeOverride: minimapCenteringModeOverride
            ) { targetOrigin in
              requestViewportScroll(targetOrigin)
            }
          } else if !viewModel.isEmpty {
            PolicyCanvasHiddenMinimapRecenterButton(viewModel: viewModel)
          }
          PolicyCanvasShortcutsDisclosure()
        }
        .policyCanvasResolvedThemeScope(resolvedCanvasColorScheme)
        .padding(14)
      }
  }
}

private struct PolicyCanvasHiddenMinimapRecenterButton: View {
  let viewModel: PolicyCanvasViewModel
  @AppStorage(PolicyCanvasMinimapDefaults.isVisibleKey)
  private var minimapVisible = PolicyCanvasMinimapDefaults.isVisibleDefault
  @FocusState private var recenterButtonFocused: Bool

  var body: some View {
    Button {
      viewModel.requestViewportCentering(.document)
    } label: {
      Image(systemName: "dot.scope")
        .imageScale(.large)
        .frame(width: 32, height: 32)
        .contentShape(Rectangle())
    }
    .buttonStyle(PolicyCanvasHiddenMinimapRecenterButtonStyle(isFocused: recenterButtonFocused))
    .focusable()
    .focused($recenterButtonFocused)
    .help("Recenter policy canvas")
    .accessibilityLabel("Recenter policy")
    .accessibilityHint("Scrolls the canvas to center the policy")
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasHiddenMinimapRecenterButton)
    .contextMenu {
      Button {
        minimapVisible = true
      } label: {
        Label("Show minimap", systemImage: "eye")
      }
    }
  }

  private struct PolicyCanvasHiddenMinimapRecenterButtonStyle: ButtonStyle {
    let isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .foregroundStyle(
          PolicyCanvasVisualStyle.activeTint.opacity(
            configuration.isPressed ? 1.0 : (isFocused ? 0.96 : 0.78)
          )
        )
        .opacity(configuration.isPressed ? 0.72 : 1)
        .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
        .shadow(
          color: PolicyCanvasVisualStyle.activeTint.opacity(isFocused ? 0.42 : 0),
          radius: isFocused ? 6 : 0
        )
        .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
        .animation(.easeOut(duration: 0.14), value: isFocused)
    }
  }
}
