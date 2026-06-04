import AppKit
import SwiftUI

extension EnvironmentValues {
  /// Gates ``SwiftUI/View/harnessTrackpadSwipeOptOut()``. When `false` the
  /// surface stops reserving its region, so a retained-but-hidden route (the
  /// dashboard keeps every route mounted and toggles visibility) never
  /// suppresses the history swipe over whichever route is actually on screen.
  @Entry var harnessTrackpadSwipeOptOutActive: Bool = true
}

extension View {
  /// Marks a surface that legitimately consumes horizontal two-finger scrolling
  /// — the policy canvas pans on that axis — so the Safari-style history swipe
  /// yields to it while the pointer is over the surface and still fires
  /// everywhere else in the window.
  func harnessTrackpadSwipeOptOut() -> some View {
    modifier(HarnessTrackpadSwipeOptOutModifier())
  }
}

private struct HarnessTrackpadSwipeOptOutModifier: ViewModifier {
  @Environment(\.harnessTrackpadSwipeOptOutActive)
  private var isActive

  func body(content: Content) -> some View {
    content.background(
      HarnessTrackpadSwipeOptOutMarker(isActive: isActive)
        .accessibilityHidden(true)
    )
  }
}

private struct HarnessTrackpadSwipeOptOutMarker: NSViewRepresentable {
  let isActive: Bool

  func makeNSView(context: Context) -> HarnessTrackpadSwipeOptOutMarkerView {
    let view = HarnessTrackpadSwipeOptOutMarkerView()
    view.isActive = isActive
    return view
  }

  func updateNSView(_ nsView: HarnessTrackpadSwipeOptOutMarkerView, context: Context) {
    nsView.isActive = isActive
  }

  static func dismantleNSView(
    _ nsView: HarnessTrackpadSwipeOptOutMarkerView,
    coordinator: ()
  ) {
    nsView.detach()
  }
}

final class HarnessTrackpadSwipeOptOutMarkerView: NSView {
  var isActive = true {
    didSet { syncRegistration() }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    // Geometry-only marker: the swipe monitor reads its frame, it never
    // intercepts events, so clicks and scrolls fall straight through to the
    // canvas it backs.
    nil
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    syncRegistration()
  }

  func detach() {
    HarnessTrackpadSwipeOptOutRegistry.shared.unregister(self)
  }

  private func syncRegistration() {
    if isActive, window != nil {
      HarnessTrackpadSwipeOptOutRegistry.shared.register(self)
    } else {
      HarnessTrackpadSwipeOptOutRegistry.shared.unregister(self)
    }
  }
}

/// Window-scoped set of explicit opt-out regions plus generic AppKit probes for
/// nested horizontal scroll views. The trackpad swipe monitor consults this
/// before starting a gesture so real content scrolling wins over route history.
@MainActor
final class HarnessTrackpadSwipeOptOutRegistry {
  static let shared = HarnessTrackpadSwipeOptOutRegistry()

  private let regions = NSHashTable<NSView>.weakObjects()
  private let horizontalScrollTolerance: CGFloat = 1

  func register(_ view: NSView) {
    regions.add(view)
  }

  func unregister(_ view: NSView) {
    regions.remove(view)
  }

  /// True when `pointInWindow` (window base coordinates) falls inside any
  /// explicit opt-out region or a horizontal scroll view hosted in `window`.
  func suppressesSwipe(at pointInWindow: NSPoint, in window: NSWindow) -> Bool {
    registeredRegionContains(pointInWindow, in: window)
      || horizontalScrollView(at: pointInWindow, in: window) != nil
  }

  /// True when the gesture should yield to content under the pointer. Explicit
  /// opt-out regions always win; otherwise a nested horizontal scroll view only
  /// suppresses history if it can still consume the current x-axis delta.
  func suppressesSwipe(at pointInWindow: NSPoint, deltaX: CGFloat, in window: NSWindow) -> Bool {
    if registeredRegionContains(pointInWindow, in: window) {
      return true
    }
    guard let scrollView = horizontalScrollView(at: pointInWindow, in: window) else {
      return false
    }
    return canConsumeHorizontalScroll(in: scrollView, deltaX: deltaX)
  }

  private func registeredRegionContains(_ pointInWindow: NSPoint, in window: NSWindow) -> Bool {
    for view in regions.allObjects where view.window === window {
      let frameInWindow = view.convert(view.bounds, to: nil)
      if !frameInWindow.isEmpty, frameInWindow.contains(pointInWindow) {
        return true
      }
    }
    return false
  }

  private func horizontalScrollView(at pointInWindow: NSPoint, in window: NSWindow) -> NSScrollView?
  {
    guard let contentView = window.contentView else {
      return nil
    }

    let pointInContent = contentView.convert(pointInWindow, from: nil)
    if let hitView = contentView.hitTest(pointInContent),
      let scrollView = nearestHorizontalScrollView(from: hitView, in: window, at: pointInWindow)
    {
      return scrollView
    }

    let containingScrollViews = descendantScrollViews(in: contentView).filter { scrollView in
      isHorizontalScrollCandidate(scrollView, in: window)
        && scrollView.convert(scrollView.bounds, to: nil).contains(pointInWindow)
    }
    return smallestScrollView(containingScrollViews)
  }

  private func nearestHorizontalScrollView(
    from view: NSView,
    in window: NSWindow,
    at pointInWindow: NSPoint
  ) -> NSScrollView? {
    var currentView: NSView? = view
    while let candidate = currentView {
      if let scrollView = candidate as? NSScrollView,
        isHorizontalScrollCandidate(scrollView, in: window),
        scrollView.convert(scrollView.bounds, to: nil).contains(pointInWindow)
      {
        return scrollView
      }
      currentView = candidate.superview
    }
    return nil
  }

  private func canConsumeHorizontalScroll(in scrollView: NSScrollView, deltaX: CGFloat) -> Bool {
    guard abs(deltaX) > horizontalScrollTolerance else {
      return false
    }

    let maxOffset = maxHorizontalOffset(in: scrollView)
    guard maxOffset > horizontalScrollTolerance else {
      return false
    }

    let currentOffset = min(max(scrollView.documentVisibleRect.minX, 0), maxOffset)
    if deltaX > 0 {
      return currentOffset > horizontalScrollTolerance
    }
    return currentOffset < maxOffset - horizontalScrollTolerance
  }

  private func isHorizontalScrollCandidate(_ scrollView: NSScrollView, in window: NSWindow) -> Bool
  {
    scrollView.window === window
      && !scrollView.isHidden
      && !scrollView.frame.isEmpty
      && scrollView.documentView != nil
      && maxHorizontalOffset(in: scrollView) > horizontalScrollTolerance
  }

  private func maxHorizontalOffset(in scrollView: NSScrollView) -> CGFloat {
    guard let documentView = scrollView.documentView else {
      return 0
    }
    return max(0, documentView.frame.width - scrollView.documentVisibleRect.width)
  }

  private func smallestScrollView(_ scrollViews: [NSScrollView]) -> NSScrollView? {
    scrollViews.min { left, right in
      area(left.convert(left.bounds, to: nil)) < area(right.convert(right.bounds, to: nil))
    }
  }

  private func area(_ rect: NSRect) -> CGFloat {
    guard !rect.isEmpty else {
      return 0
    }
    return rect.width * rect.height
  }

  private func descendantScrollViews(in root: NSView) -> [NSScrollView] {
    var result: [NSScrollView] = []
    var stack = [root]
    while let view = stack.popLast() {
      if let scrollView = view as? NSScrollView {
        result.append(scrollView)
      }
      stack.append(contentsOf: view.subviews)
    }
    return result
  }
}
