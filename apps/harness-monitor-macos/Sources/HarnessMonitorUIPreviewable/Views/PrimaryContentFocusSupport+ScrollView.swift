import AppKit

extension PrimaryContentPagingResponderBridgeView {
  func resolvedScrollView() -> NSScrollView? {
    if let enclosingScrollView {
      return enclosingScrollView
    }
    let markerCenter = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
    var ancestor = superview
    while let current = ancestor {
      let candidate = descendantScrollViews(in: current)
        .filter { scrollView in
          let frameInWindow = scrollView.convert(scrollView.bounds, to: nil)
          return frameInWindow.insetBy(dx: -1, dy: -1).contains(markerCenter)
        }
        .min { lhs, rhs in
          area(of: lhs) < area(of: rhs)
        }
      if let candidate {
        return candidate
      }
      ancestor = current.superview
    }
    return nil
  }

  func descendantScrollViews(in root: NSView) -> [NSScrollView] {
    var results: [NSScrollView] = []
    if let scrollView = root as? NSScrollView {
      results.append(scrollView)
    }
    for subview in root.subviews {
      results.append(contentsOf: descendantScrollViews(in: subview))
    }
    return results
  }

  func area(of view: NSView) -> CGFloat {
    let frameInWindow = view.convert(view.bounds, to: nil)
    return max(frameInWindow.width, 1) * max(frameInWindow.height, 1)
  }
}
