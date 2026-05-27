import SwiftUI

extension PolicyCanvasView {
  @ViewBuilder var policyCanvasSplitLayout: some View {
    SessionContentDetailSplitView(
      contentWidth: $componentLibraryWidthState,
      commitContentWidth: { componentLibraryWidth = $0 },
      dividerAccessibilityIdentifier:
        HarnessMonitorAccessibility.policyCanvasComponentLibraryDivider,
      showsDividerLine: false,
      content: {
        PolicyCanvasComponentLibraryPane(viewModel: viewModel)
      },
      detail: {
        PolicyCanvasViewport(
          viewModel: viewModel,
          focusedComponent: $focusedComponentState,
          selectionFocusRequest: selectionFocusRequest,
          showSimulationOverlay: simulationOverlayResolved,
          sceneFocusEnabled: sceneFocusEnabled,
          suppressesSceneStorage: suppressesSceneStorage,
          storedPipelineStateRaw: storedPipelineStateRaw,
          openEditor: presentEditSheet
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
