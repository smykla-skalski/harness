import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

extension PolicyCanvasView {
  @ViewBuilder var policyCanvasSplitLayout: some View {
    // Fixed two-pane layout: the component library hugs its own content width
    // (see `PolicyCanvasComponentLibraryPane`) and the detail pane takes the
    // rest. The library is intentionally not user-resizable — it shows a fixed
    // set of palette actions, so a draggable divider could only add or waste
    // horizontal space.
    HStack(spacing: 0) {
      PolicyCanvasComponentLibraryPane(viewModel: viewModel)

      policyCanvasDetailPane
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder var policyCanvasDetailPane: some View {
    VStack(spacing: 0) {
      PolicyCanvasTopBar(
        viewModel: viewModel,
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
          policyCanvasViewportPane
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
    .overlay(alignment: .topTrailing) {
      PolicyCanvasSelectionEditButton(
        isDisabled: currentEditSheet == nil,
        open: presentCurrentEditSheet
      )
      .padding(14)
    }
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

private struct PolicyCanvasSelectionEditButton: View {
  let isDisabled: Bool
  let open: @MainActor () -> Void

  var body: some View {
    Button(action: open) {
      Label("Edit", systemImage: "square.and.pencil")
        .scaledFont(.caption.weight(.semibold))
        .lineLimit(1)
    }
    .harnessActionButtonStyle(variant: .bordered, tint: PolicyCanvasVisualStyle.activeTint)
    .controlSize(.small)
    .disabled(isDisabled)
    .help(isDisabled ? "Select a policy component to edit" : "Edit selected policy component")
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasEditButton)
  }
}
