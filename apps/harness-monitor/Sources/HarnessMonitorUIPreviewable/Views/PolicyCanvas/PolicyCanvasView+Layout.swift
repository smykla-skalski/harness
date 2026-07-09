import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

extension PolicyCanvasView {
  @ViewBuilder var policyCanvasSplitLayout: some View {
    // Fixed-width side columns around a flexible detail pane: the component
    // library hugs its own content width (see `PolicyCanvasComponentLibraryPane`)
    // and the confidence pane is a fixed trailing column (see
    // `policyCanvasConfidencePane`). Both are deliberately in-layout rather than
    // a SwiftUI `.inspector`: presenting a native inspector here promoted a
    // third NavigationSplitView column, which split the window toolbar and let
    // the detail underlap the translucent sidebar (hiding this very library).
    // The detail pane takes the remaining width.
    if policyCanvasDisplayMode == .canvas {
      HStack(spacing: 0) {
        PolicyCanvasComponentLibraryPane(viewModel: viewModel)
          .policyCanvasPaneFontScaleBoost()

        policyCanvasDetailPane
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        if policyCanvasInspectorVisible {
          policyCanvasConfidencePane
            .policyCanvasPaneFontScaleBoost()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      policyCanvasDetailPane
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  @ViewBuilder var policyCanvasDetailPane: some View {
    VStack(spacing: 0) {
      PolicyCanvasTopBar(
        viewModel: viewModel,
        displayMode: policyCanvasDisplayModeBinding,
        liveStatus: viewModel.liveStatus,
        canMakeLive: viewModel.canMakeLive,
        remoteActionsEnabled: remoteActionsEnabled,
        remoteActionDisabledReason: remoteActionDisabledReason,
        reflowLayout: {
          viewModel.requestAtomicReflow(preserveManualAnchors: false, force: true)
        },
        makeLive: requestMakeLive
      )

      ZStack(alignment: .top) {
        VStack(spacing: 0) {
          switch policyCanvasDisplayMode {
          case .canvas:
            policyCanvasViewportPane
          case .json:
            PolicyCanvasJSONDocumentView(viewModel: viewModel)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        PolicyCanvasChromeBannerOverlay(
          viewModel: viewModel,
          retrySave: saveDraft,
          recoverEdits: recoverRejectedEdits,
          dismissRecovery: {
            viewModel.clearRecoveryBuffer()
          }
        )
        .padding(.horizontal, 14)
        .padding(.top, 10)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder var policyCanvasViewportPane: some View {
    PolicyCanvasViewport(
      viewModel: viewModel,
      focusedComponent: $focusedComponentState,
      selectionFocusRequest: selectionFocusRequest,
      showSimulationOverlay: false,
      sceneFocusEnabled: sceneFocusEnabled,
      suppressesSceneStorage: suppressesSceneStorage,
      storedPipelineStateRaw: storedPipelineStateRaw,
      openEditor: presentEditSheet,
      requestKeyboardFocus: requestCanvasKeyboardFocus,
      persistViewportState: { viewportState, identity in
        persistSceneStorageIfNeeded(viewportState, for: identity)
      },
      saveDraft: saveDraft,
      canSave: remoteActionsEnabled,
      isInspectorVisible: policyCanvasInspectorVisible,
      canToggleInspector: true,
      toggleInspector: togglePolicyCanvasInspector
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  var currentEditSheet: PolicyCanvasEditSheet? {
    if !viewModel.secondarySelections.isEmpty {
      return .selection
    }
    switch viewModel.selection {
    case .node(let id):
      return viewModel.node(id) == nil ? nil : .node(id)
    case .group(let id):
      return viewModel.group(id) == nil ? nil : .group(id)
    case .edge(let id):
      return viewModel.edges.contains { $0.id == id } ? .edge(id) : nil
    case nil:
      return nil
    }
  }

  func presentCurrentEditSheet() {
    presentEditSheet(currentEditSheet)
  }

  func presentEditSheet(_ sheet: PolicyCanvasEditSheet?) {
    guard let sheet else {
      return
    }
    if let primarySelection = sheet.primarySelection {
      viewModel.select(primarySelection)
    }
    presentedEditSheet = sheet
  }
}

private enum PolicyCanvasSidePaneMetrics {
  /// The component-library and confidence side panes lean on caption/caption2
  /// copy, which reads a touch small at the standard app text size. Nudge their
  /// base size up a notch.
  static let fontScaleBoost: CGFloat = 1.15
}

extension View {
  /// Multiplies the inherited `\.fontScale` for a canvas side pane so its base
  /// text is a little larger by default while still tracking the app text-size
  /// setting (proportional at every size). Scoped to the pane it wraps, so the
  /// detail canvas - a sibling outside the subtree - is unaffected.
  fileprivate func policyCanvasPaneFontScaleBoost() -> some View {
    modifier(PolicyCanvasSidePaneFontScaleBoostModifier())
  }
}

private struct PolicyCanvasSidePaneFontScaleBoostModifier: ViewModifier {
  @Environment(\.fontScale)
  private var fontScale

  func body(content: Content) -> some View {
    content.environment(
      \.fontScale,
      fontScale * PolicyCanvasSidePaneMetrics.fontScaleBoost
    )
  }
}
