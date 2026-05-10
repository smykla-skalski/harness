import AppKit
import SwiftUI

/// Re-arms the SwiftUI `.searchable` field's suggestion menu when the
/// hosting window regains key state.
///
/// SwiftUI's `.searchSuggestions` is backed by the AppKit suggestion
/// menu attached to `NSSearchField`. That menu dismisses when the
/// window resigns key/active and does NOT reappear automatically when
/// the window regains key. There is no SwiftUI-only API to force
/// re-presentation. The community-documented fix
/// (https://github.com/siteline/swiftui-introspect/discussions/397)
/// is to bridge into AppKit, find the `NSSearchField` instance in the
/// window's view hierarchy, and make that field first responder. The
/// `beginSearchInteraction()` API lives on `NSSearchToolbarItem`, not
/// `NSSearchField`, so field-backed SwiftUI search has to stay with the
/// responder-chain bridge.
///
/// `shouldRebind` gates the rebinding so we only fire when the user
/// has a non-empty query AND the search bar is still presented; the
/// no-op case avoids re-arming an empty search.
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
    private var observer: NSObjectProtocol?
    private var shouldRebind = false

    func update(shouldRebind newValue: Bool) {
      shouldRebind = newValue
    }

    func attach(to window: NSWindow?) {
      guard window !== observedWindow else { return }
      detach()
      observedWindow = window
      guard let window else { return }
      observer = NotificationCenter.default.addObserver(
        forName: NSWindow.didBecomeKeyNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.rearmIfNeeded(in: window)
        }
      }
    }

    private func detach() {
      if let observer {
        NotificationCenter.default.removeObserver(observer)
      }
      observer = nil
      observedWindow = nil
    }

    private func rearmIfNeeded(in window: NSWindow) {
      guard shouldRebind else { return }
      guard let field = locateSearchField(in: window.contentView) else {
        return
      }
      window.makeFirstResponder(field)
      field.selectText(nil)
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

    deinit {
      if let observer {
        NotificationCenter.default.removeObserver(observer)
      }
    }
  }
}
