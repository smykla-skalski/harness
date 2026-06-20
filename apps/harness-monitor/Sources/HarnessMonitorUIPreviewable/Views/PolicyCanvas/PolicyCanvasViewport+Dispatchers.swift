@MainActor
func policyCanvasZoomFocusDispatcher(
  viewModel: PolicyCanvasViewModel
) -> PolicyCanvasZoomFocusDispatcher {
  let dispatcher = PolicyCanvasZoomFocusDispatcher()
  dispatcher.zoomIn = {
    viewModel.clearPinchAnchor()
    viewModel.zoomIn()
  }
  dispatcher.zoomOut = {
    viewModel.clearPinchAnchor()
    viewModel.zoomOut()
  }
  dispatcher.resetZoom = {
    viewModel.clearPinchAnchor()
    viewModel.resetZoom()
  }
  return dispatcher
}

@MainActor
func policyCanvasLayoutFocusDispatcher(
  viewModel: PolicyCanvasViewModel
) -> PolicyCanvasLayoutFocusDispatcher {
  let dispatcher = PolicyCanvasLayoutFocusDispatcher()
  dispatcher.reflowLayout = {
    viewModel.requestAtomicReflow(preserveManualAnchors: false, force: true)
  }
  return dispatcher
}

@MainActor
func policyCanvasSaveFocusDispatcher(
  saveDraft: @escaping @MainActor () -> Void
) -> PolicyCanvasSaveFocusDispatcher {
  let dispatcher = PolicyCanvasSaveFocusDispatcher()
  dispatcher.save = saveDraft
  return dispatcher
}

@MainActor
func policyCanvasInspectorFocusDispatcher(
  toggleInspector: @escaping @MainActor () -> Void
) -> PolicyCanvasInspectorFocusDispatcher {
  let dispatcher = PolicyCanvasInspectorFocusDispatcher()
  dispatcher.toggleInspector = toggleInspector
  return dispatcher
}

struct PolicyCanvasCommandFocusInput {
  let zoomFocusDispatcher: PolicyCanvasZoomFocusDispatcher
  let canReflow: Bool
  let layoutFocusDispatcher: PolicyCanvasLayoutFocusDispatcher
  let canSave: Bool
  let saveFocusDispatcher: PolicyCanvasSaveFocusDispatcher
  let isInspectorVisible: Bool
  let canToggleInspector: Bool
  let inspectorFocusDispatcher: PolicyCanvasInspectorFocusDispatcher
}

func policyCanvasCommandFocus(
  input: PolicyCanvasCommandFocusInput
) -> PolicyCanvasCommandFocus {
  PolicyCanvasCommandFocus(
    zoom: PolicyCanvasZoomFocus(dispatcher: input.zoomFocusDispatcher),
    layout: PolicyCanvasLayoutFocus(
      canReflow: input.canReflow,
      dispatcher: input.layoutFocusDispatcher
    ),
    save: PolicyCanvasSaveFocus(
      canSave: input.canSave,
      dispatcher: input.saveFocusDispatcher
    ),
    inspector: PolicyCanvasInspectorFocus(
      isVisible: input.isInspectorVisible,
      canToggle: input.canToggleInspector,
      dispatcher: input.inspectorFocusDispatcher
    )
  )
}
