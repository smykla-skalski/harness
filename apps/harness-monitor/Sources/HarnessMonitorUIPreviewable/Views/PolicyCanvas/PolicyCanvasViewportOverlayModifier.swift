import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

private let policyCanvasViewportOverlayEdgePadding: CGFloat = 14

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
            .padding(policyCanvasViewportOverlayEdgePadding)
        }
      }
      .overlay(alignment: .bottomLeading) {
        PolicyCanvasZoomControls(viewModel: viewModel)
          .policyCanvasResolvedThemeScope(resolvedCanvasColorScheme)
          .padding(policyCanvasViewportOverlayEdgePadding)
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
            .padding(minimapVisible ? 0 : policyCanvasViewportOverlayEdgePadding)
        }
        .policyCanvasResolvedThemeScope(resolvedCanvasColorScheme)
        .padding(minimapVisible ? policyCanvasViewportOverlayEdgePadding : 0)
      }
  }
}

private struct PolicyCanvasHiddenMinimapRecenterButton: View {
  let viewModel: PolicyCanvasViewModel
  @AppStorage(PolicyCanvasMinimapDefaults.isVisibleKey)
  private var minimapVisible = PolicyCanvasMinimapDefaults.isVisibleDefault
  @State private var recenterButtonHovered = false
  @FocusState private var recenterButtonFocused: Bool

  private var recenterButtonActive: Bool {
    recenterButtonFocused || recenterButtonHovered
  }

  var body: some View {
    Button {
      viewModel.requestViewportCentering(.document)
    } label: {
      Image(systemName: "dot.scope")
        .font(.title2.weight(recenterButtonActive ? .heavy : .regular))
        .frame(width: 32, height: 32)
        .padding(policyCanvasViewportOverlayEdgePadding)
        .contentShape(Rectangle())
    }
    .buttonStyle(
      PolicyCanvasHiddenMinimapRecenterButtonStyle(
        isFocused: recenterButtonActive
      )
    )
    .focusable()
    .focused($recenterButtonFocused)
    .onHover { hovering in
      recenterButtonHovered = hovering
    }
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
          configuration.isPressed || isFocused
            ? PolicyCanvasVisualStyle.activeTint
            : PolicyCanvasVisualStyle.secondaryText
        )
        .opacity(configuration.isPressed ? 0.72 : 1)
        .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
        .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
        .animation(.easeOut(duration: 0.14), value: isFocused)
    }
  }
}
