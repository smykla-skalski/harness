enum PolicyCanvasViewportCenteringBehavior: Equatable {
  case document
  case documentAfterRouteComputation
  case selectionIfPresent

  var usesRestoredViewportOrigin: Bool {
    self != .documentAfterRouteComputation
  }
}
