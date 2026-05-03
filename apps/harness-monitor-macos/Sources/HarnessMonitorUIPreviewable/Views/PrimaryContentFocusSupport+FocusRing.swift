import AppKit

extension PrimaryContentPagingResponderBridgeView {
  func suppressFocusRings(on responders: [NSResponder?]) {
    restoreSuppressedFocusRings()
    for responder in responders {
      guard let view = responder as? NSView else {
        continue
      }
      suppressedFocusRingStates.append(
        SuppressedFocusRingState(
          view: view,
          originalFocusRingType: view.focusRingType
        )
      )
      view.focusRingType = .none
    }
  }

  func restoreSuppressedFocusRings() {
    for suppressedState in suppressedFocusRingStates {
      guard let view = suppressedState.view else {
        continue
      }
      view.focusRingType = suppressedState.originalFocusRingType
    }
    suppressedFocusRingStates.removeAll()
  }
}
