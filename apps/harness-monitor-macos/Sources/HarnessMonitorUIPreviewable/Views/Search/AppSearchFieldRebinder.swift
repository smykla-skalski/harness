import AppKit
import SwiftUI

/// Re-arms the SwiftUI `.searchable` field's suggestion menu when
/// the hosting window regains key state OR the user clicks back into
/// the field while it's still first responder.
///
/// SwiftUI's `.searchSuggestions` is backed by the AppKit suggestion
/// menu attached to `NSSearchField`. That menu dismisses any time the
/// window resigns key OR a different responder takes focus, and does
/// NOT reappear automatically. There is no SwiftUI-only API to force
/// re-presentation. The community-documented bridge
/// (https://github.com/siteline/swiftui-introspect/discussions/397)
/// is to find the `NSSearchField` in the window's view hierarchy and
/// make it first responder. The `beginSearchInteraction()` API lives
/// on `NSSearchToolbarItem`, not `NSSearchField`, so field-backed
/// SwiftUI search has to stay with the responder-chain bridge.
///
/// Two re-arm paths are needed because the dismissal modes don't
/// share a notification:
///
/// 1. `NSWindow.didBecomeKeyNotification` — fires when the window
///    transitions back to key (e.g. ⌘-tab into the app). Re-arm by
///    cycling first responder off and back onto the search field so
///    AppKit re-presents the menu even when the field never lost
///    first-responder status across the resign/key flip.
/// 2. `.leftMouseDown` local event monitor — fires when the user
///    clicks anywhere in the window. If the click hit the search
///    field while we have a non-empty query, the menu was almost
///    certainly dismissed by an earlier focus event with no
///    notification we could observe; force the same FR cycle.
///
/// `shouldRebind` gates both paths so we only fire when the user has
/// a non-empty query AND the search bar is still presented.
struct AppSearchFieldRebinder: NSViewRepresentable {
  let shouldRebind: Bool

  func makeNSView(context: Context) -> NSView {
    let view = AnchorView()
    view.coordinator = context.coordinator
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.update(shouldRebind: shouldRebind)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.detach()
  }

  /// Empty `NSView` that anchors the modifier into the SwiftUI tree.
  /// Its only job is to give the coordinator a `window` to attach
  /// notifications to.
  private final class AnchorView: NSView {
    weak var coordinator: Coordinator?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      coordinator?.attach(to: window)
    }
  }

  @MainActor
  final class Coordinator: NSObject {
    private weak var observedWindow: NSWindow?
    private var keyObserver: NSObjectProtocol?
    private var clickMonitor: Any?
    private var shouldRebind = false

    func update(shouldRebind newValue: Bool) {
      shouldRebind = newValue
    }

    func attach(to window: NSWindow?) {
      guard window !== observedWindow else { return }
      detach()
      observedWindow = window
      guard let window else { return }
      keyObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didBecomeKeyNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.rearmIfNeeded(in: window)
        }
      }
      clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) {
        [weak self] event in
        // AppKit dispatches local mouse events on the main thread; we
        // bridge synchronously so rearming happens BEFORE AppKit hands
        // the click to the field. Going through Task { @MainActor }
        // queues to the next runloop tick, by which point the field
        // has already absorbed the click and the FR cycle becomes a
        // visible flicker that doesn't reliably re-open the menu.
        MainActor.assumeIsolated {
          self?.handleClick(event)
        }
        return event
      }
    }

    func detach() {
      if let keyObserver {
        NotificationCenter.default.removeObserver(keyObserver)
      }
      keyObserver = nil
      if let clickMonitor {
        NSEvent.removeMonitor(clickMonitor)
      }
      clickMonitor = nil
      observedWindow = nil
    }

    private func handleClick(_ event: NSEvent) {
      guard shouldRebind else { return }
      guard let window = observedWindow, event.window === window else {
        return
      }
      guard let field = locateSearchField(in: window.contentView) else { return }
      let pointInField = field.convert(event.locationInWindow, from: nil)
      guard field.bounds.contains(pointInField) else { return }
      rearm(field: field, in: window)
    }

    private func rearmIfNeeded(in window: NSWindow) {
      guard shouldRebind else { return }
      guard let field = locateSearchField(in: window.contentView) else {
        return
      }
      rearm(field: field, in: window)
    }

    private func rearm(field: NSSearchField, in window: NSWindow) {
      // AppKit's suggestion menu re-presents on a fresh
      // becomeFirstResponder; if `field` is already first responder,
      // `makeFirstResponder` is a no-op. Cycle off then back on to
      // force the menu to reopen while keeping the typed query. The
      // restore step is dispatched on the next main runloop pass so
      // the resign-first-responder propagation completes before the
      // field is asked to take responder status again — without that
      // ordering, AppKit collapses the pair into a single no-op.
      window.makeFirstResponder(nil)
      DispatchQueue.main.async { [weak window] in
        guard let window else { return }
        window.makeFirstResponder(field)
        field.selectText(nil)
      }
    }

    private func locateSearchField(in view: NSView?) -> NSSearchField? {
      guard let view else { return nil }
      if let field = view as? NSSearchField {
        return field
      }
      for subview in view.subviews {
        if let match = locateSearchField(in: subview) {
          return match
        }
      }
      return nil
    }
  }
}
