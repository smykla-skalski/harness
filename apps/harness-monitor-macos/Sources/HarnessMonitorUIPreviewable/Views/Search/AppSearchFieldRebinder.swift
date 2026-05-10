import AppKit
import SwiftUI

/// Re-arms the SwiftUI `.searchable` field's suggestion menu when
/// the hosting window regains key state.
///
/// SwiftUI's `.searchSuggestions` is backed by the AppKit suggestion
/// menu attached to `NSSearchField`. That menu dismisses when the
/// window resigns key/active and does NOT reappear automatically when
/// the window regains it. The community-documented bridge
/// (https://github.com/siteline/swiftui-introspect/discussions/397)
/// is to find the `NSSearchField` in the window's view hierarchy and
/// cycle first-responder off and back on so AppKit re-presents the
/// menu.
///
/// `shouldRebind` gates the cycle so we only fire when the user has
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
    }

    func detach() {
      if let keyObserver {
        NotificationCenter.default.removeObserver(keyObserver)
      }
      keyObserver = nil
      observedWindow = nil
    }

    private func rearmIfNeeded(in window: NSWindow) {
      // Window-key path: no click is coming, so we drive the FR
      // cycle ourselves. Resign synchronously, restore on the next
      // runloop pass so AppKit fully propagates the
      // resignFirstResponder before we re-promote — without the
      // delay AppKit collapses the pair into a no-op and the menu
      // stays dismissed.
      guard shouldRebind else { return }
      guard let field = locateSearchField(in: window.contentView) else {
        return
      }
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
