enum PolicyCanvasViewportCenteringBehavior: Equatable {
  case document
  case documentAfterRouteComputation
  case selectionIfPresent

  var allowsProvisionalRouteOutput: Bool {
    self != .documentAfterRouteComputation
  }

  var usesRestoredViewportOrigin: Bool {
    self != .documentAfterRouteComputation
  }
}
