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
        canPromote: viewModel.canPromote,
        remoteActionsEnabled: remoteActionsEnabled,
        remoteActionDisabledReason: remoteActionDisabledReason,
        simulationOverlayAvailable: simulationOverlayAvailable,
        simulationOverlayVisible: simulationOverlayResolved,
        toggleSimulationOverlay: toggleSimulationOverlay,
        reflowLayout: { viewModel.reflowLayout() },
        save: saveDraft,
        simulate: simulate,
        promote: requestPromote,
        recoverEdits: recoverRejectedEdits
      )

      PolicyCanvasValidationPanel(
        viewModel: viewModel,
        focus: { resolved in
          viewModel.focusIssue(resolved)
          if let selection = resolved.focusSelection {
            selectionFocusRequestID &+= 1
            selectionFocusRequest = PolicyCanvasViewportSelectionFocusRequest(
              id: selectionFocusRequestID,
              selection: selection
            )
          }
        }
      )

      policyCanvasViewportPane
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder var policyCanvasViewportPane: some View {
    PolicyCanvasViewport(
      viewModel: viewModel,
      focusedComponent: $focusedComponentState,
      selectionFocusRequest: selectionFocusRequest,
      showSimulationOverlay: simulationOverlayResolved,
      sceneFocusEnabled: sceneFocusEnabled,
      suppressesSceneStorage: suppressesSceneStorage,
      storedPipelineStateRaw: storedPipelineStateRaw,
      openEditor: presentEditSheet,
      requestKeyboardFocus: requestCanvasKeyboardFocus,
      saveDraft: saveDraft,
      canSave: remoteActionsEnabled
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay(alignment: .topTrailing) {
      VStack(alignment: .trailing, spacing: 12) {
        if workflowStatusVisible && !workflowStatusCards.isEmpty {
          PolicyCanvasWorkflowStatusOverlay(cards: workflowStatusCards)
        }

        PolicyCanvasSelectionEditButton(
          isDisabled: currentEditSheet == nil,
          open: presentCurrentEditSheet
        )
      }
      .padding(14)
    }
  }

  var workflowStatusCards: [PolicyCanvasWorkflowStatusCardModel] {
    viewModel.workflowStatusCards(
      remoteActionsEnabled: remoteActionsEnabled,
      remoteActionDisabledReason: remoteActionDisabledReason
    )
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
