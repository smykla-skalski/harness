import AppKit

extension NSView {
  func taskBoardAncestor<View: NSView>(of type: View.Type) -> View? {
    var candidate: NSView? = self
    while let view = candidate {
      if let match = view as? View {
        return match
      }
      candidate = view.superview
    }
    return nil
  }
}
