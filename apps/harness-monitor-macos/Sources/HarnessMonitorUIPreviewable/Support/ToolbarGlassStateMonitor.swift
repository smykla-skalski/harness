import AppKit
import SwiftUI

// NSWindow draws a titlebar/toolbar separator at the AppKit level, above all
// SwiftUI content. On macOS 26 with Liquid Glass the NavigationSplitView
// sidebar is translucent glass, so that line bleeds through the sidebar area
// even though ToolbarBaselineOverlay only draws in the detail column (starting
// at the sidebar's right edge). Setting titlebarSeparatorStyle to .none makes
// the custom overlay the sole separator, correctly scoped to the detail column.
// NSToolbar.showsBaselineSeparator was deprecated in macOS 15 - titlebarSeparatorStyle
// is the replacement (available since macOS 12).
//
// The NSView subclass uses viewDidMoveToWindow() instead of DispatchQueue.main.async
// because makeNSView is called before SwiftUI inserts the view into the window
// hierarchy. The async dispatch fires while window is still nil and the call
// silently no-ops. viewDidMoveToWindow() is the guaranteed AppKit callback that
// fires with a non-nil window. Titlebar transparency is opt-in for the surfaces
// that deliberately use a transparent titlebar.
private final class _TitlebarSeparatorSuppressorView: NSView {
  var titlebarAppearsTransparent = false
  private weak var lastAppliedWindow: NSWindow?
  private var lastAppliedTransparent: Bool?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    // Force re-apply when the window changes — the new window starts with
    // its own default chrome state.
    lastAppliedWindow = nil
    lastAppliedTransparent = nil
    applyWindowOverrides()
  }

  func applyWindowOverrides() {
    guard let window else { return }
    // SwiftUI calls updateNSView on every parent body re-evaluation. The
    // window's titlebarSeparatorStyle / titlebarAppearsTransparent / styleMask
    // are idempotent semantically, but AppKit still does validation and
    // potential re-layout per assignment. Cache the last applied state so
    // repeated updateNSView calls collapse to zero AppKit work once the
    // window chrome is in the desired shape.
    if lastAppliedWindow === window, lastAppliedTransparent == titlebarAppearsTransparent {
      return
    }
    window.titlebarSeparatorStyle = .none
    window.titlebarAppearsTransparent = titlebarAppearsTransparent
    if titlebarAppearsTransparent {
      window.styleMask.insert(.fullSizeContentView)
    }
    lastAppliedWindow = window
    lastAppliedTransparent = titlebarAppearsTransparent
  }
}

private struct ToolbarBaselineSeparatorSuppressor: NSViewRepresentable {
  let titlebarAppearsTransparent: Bool

  func makeNSView(context: Context) -> _TitlebarSeparatorSuppressorView {
    let view = _TitlebarSeparatorSuppressorView()
    view.titlebarAppearsTransparent = titlebarAppearsTransparent
    return view
  }

  func updateNSView(_ nsView: _TitlebarSeparatorSuppressorView, context: Context) {
    nsView.titlebarAppearsTransparent = titlebarAppearsTransparent
    nsView.applyWindowOverrides()
  }
}

extension View {
  public func suppressToolbarBaselineSeparator(
    titlebarAppearsTransparent: Bool = false
  ) -> some View {
    background(
      ToolbarBaselineSeparatorSuppressor(
        titlebarAppearsTransparent: titlebarAppearsTransparent
      )
    )
  }

  public func suppressToolbarBaselineSeparator(
    markedAs identifier: String,
    titlebarAppearsTransparent: Bool = false
  ) -> some View {
    suppressToolbarBaselineSeparator(titlebarAppearsTransparent: titlebarAppearsTransparent)
      .overlay {
        AccessibilityTextMarker(identifier: identifier, text: "suppressed")
      }
  }
}

struct OptionalToolbarBaselineOverlayModifier: ViewModifier {
  let isEnabled: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if isEnabled {
      content.toolbarBaselineOverlay()
    } else {
      content
    }
  }
}
