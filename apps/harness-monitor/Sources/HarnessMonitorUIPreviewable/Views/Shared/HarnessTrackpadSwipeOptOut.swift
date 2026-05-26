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

/// Window-scoped set of regions that should swallow a horizontal two-finger
/// scroll instead of letting it drive history navigation. The trackpad swipe
/// monitor consults this before starting a gesture.
@MainActor
final class HarnessTrackpadSwipeOptOutRegistry {
  static let shared = HarnessTrackpadSwipeOptOutRegistry()

  private let regions = NSHashTable<NSView>.weakObjects()

  func register(_ view: NSView) {
    regions.add(view)
  }

  func unregister(_ view: NSView) {
    regions.remove(view)
  }

  /// True when `pointInWindow` (window base coordinates) falls inside any
  /// registered region hosted in `window`.
  func suppressesSwipe(at pointInWindow: NSPoint, in window: NSWindow) -> Bool {
    for view in regions.allObjects where view.window === window {
      let frameInWindow = view.convert(view.bounds, to: nil)
      if !frameInWindow.isEmpty, frameInWindow.contains(pointInWindow) {
        return true
      }
    }
    return false
  }
}
