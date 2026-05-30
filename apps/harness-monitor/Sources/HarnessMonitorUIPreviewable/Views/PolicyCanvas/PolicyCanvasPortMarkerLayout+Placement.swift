import SwiftUI

// One port-marker candidate while assigning side-local offsets: the assignment
// unit, its base axis coordinate, and the fan-order key used to sort siblings.
struct PolicyCanvasPortMarkerPlacement {
  let unit: PolicyCanvasPortMarkerAssignmentUnit
  let base: CGFloat
  let order: CGFloat
}
