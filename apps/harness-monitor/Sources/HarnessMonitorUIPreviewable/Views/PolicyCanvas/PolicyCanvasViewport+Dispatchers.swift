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

func policyCanvasCommandFocus(
  zoomFocusDispatcher: PolicyCanvasZoomFocusDispatcher,
  canReflow: Bool,
  layoutFocusDispatcher: PolicyCanvasLayoutFocusDispatcher,
  canSave: Bool,
  saveFocusDispatcher: PolicyCanvasSaveFocusDispatcher,
  isInspectorVisible: Bool,
  canToggleInspector: Bool,
  inspectorFocusDispatcher: PolicyCanvasInspectorFocusDispatcher
) -> PolicyCanvasCommandFocus {
  PolicyCanvasCommandFocus(
    zoom: PolicyCanvasZoomFocus(dispatcher: zoomFocusDispatcher),
    layout: PolicyCanvasLayoutFocus(
      canReflow: canReflow,
      dispatcher: layoutFocusDispatcher
    ),
    save: PolicyCanvasSaveFocus(
      canSave: canSave,
      dispatcher: saveFocusDispatcher
    ),
    inspector: PolicyCanvasInspectorFocus(
      isVisible: isInspectorVisible,
      canToggle: canToggleInspector,
      dispatcher: inspectorFocusDispatcher
    )
  )
}
