import AppKit
import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

/// NSPanel subclass that opts in to becoming key so the SwiftUI palette's
/// TextField can take first-responder and receive keystrokes. Pattern
/// follows Cindori's canonical "FloatingPanel" recipe for Spotlight-style
/// command palettes:
/// https://cindori.com/developer/floating-panel
final class OpenAnythingFloatingPanel: NSPanel {
  /// Closure invoked when the panel resigns main (user clicked outside or
  /// switched apps). The controller hooks this to drive `model.dismiss`.
  var onResignMain: (() -> Void)?

  override var canBecomeKey: Bool { true }
  // Returning `true` here matters: SwiftUI focus state inside the panel only
  // promotes the TextField to first responder when both flags are true.
  override var canBecomeMain: Bool { true }

  override func resignMain() {
    super.resignMain()
    onResignMain?()
  }
}

/// Owns the floating NSPanel that hosts `OpenAnythingPaletteView`. Cmd+K
/// toggles, Escape dismisses, clicking outside the panel dismisses, and the
/// panel floats above whichever Monitor window is active so the feature is
/// genuinely global instead of pinned to one host scene.
@MainActor
final class OpenAnythingPaletteWindowController: NSObject {
  let model: OpenAnythingPaletteModel
  private var executor: ((OpenAnythingHit) -> Void)?
  private var panel: OpenAnythingFloatingPanel?
  /// Re-entrancy guard so the model->panel sync and panel->model sync do not
  /// chase each other into a loop on dismiss.
  private var isClosing = false

  init(model: OpenAnythingPaletteModel) {
    self.model = model
    super.init()
  }

  /// Bind the route executor late: the App's scene wiring needs `openWindow`,
  /// store, and review registry to build the closure, none of which are
  /// available at `HarnessMonitorApp.init` time. Safe to call repeatedly.
  ///
  /// Also eagerly constructs the panel + NSHostingView the first time
  /// binding lands so the first Cmd+K does not pay the SwiftUI tree
  /// instantiation cost on the keystroke (which read as a perceptible
  /// delay before the floating card appeared).
  func bindExecutor(_ executor: @escaping (OpenAnythingHit) -> Void) {
    self.executor = executor
    if let panel {
      panel.contentView = makeHostingView()
    } else {
      let built = buildPanel()
      panel = built
      prewarm(built)
    }
  }

  /// Briefly orders the panel onscreen far offscreen so macOS finishes the
  /// CALayer + NSHostingView first-render work before the user presses
  /// Cmd+K. Without this the first invocation pays for the lazy layout
  /// inline with the keystroke and reads as a perceptible delay.
  private func prewarm(_ panel: OpenAnythingFloatingPanel) {
    let size = panel.frame.size
    panel.setFrame(
      NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
      display: false
    )
    panel.orderFront(nil)
    panel.displayIfNeeded()
    panel.orderOut(nil)
  }

  func toggle(scope: OpenAnythingDomain?, restoreLastQuery: Bool) {
    if model.isPresented {
      hide()
    } else {
      show(scope: scope, restoreLastQuery: restoreLastQuery)
    }
  }

  func show(scope: OpenAnythingDomain?, restoreLastQuery: Bool) {
    let panel = panel ?? buildPanel()
    self.panel = panel
    model.present(targetWindowID: nil, scope: scope, restoreLastQuery: restoreLastQuery)
    positionAboveKeyWindow(panel)
    panel.makeKeyAndOrderFront(nil)
  }

  func hide() {
    guard !isClosing else { return }
    isClosing = true
    defer { isClosing = false }
    if model.isPresented {
      model.dismiss(reason: .userCanceled)
    }
    panel?.orderOut(nil)
  }

  /// Called from the palette view when the model dismisses for an in-flight
  /// reason (ESC, hit executed, window resigned). Orders the panel out
  /// without re-dismissing the model.
  func didDismissModel() {
    guard !isClosing else { return }
    isClosing = true
    defer { isClosing = false }
    panel?.orderOut(nil)
  }

  private func buildPanel() -> OpenAnythingFloatingPanel {
    let contentRect = NSRect(
      x: 0, y: 0,
      width: OpenAnythingPaletteConstants.maxWidth,
      height: OpenAnythingPaletteConstants.maxHeight
    )
    let panel = OpenAnythingFloatingPanel(
      contentRect: contentRect,
      styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior.insert(.fullScreenAuxiliary)
    panel.collectionBehavior.insert(.transient)
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isMovableByWindowBackground = true
    // Spotlight-style auto-hide when the user clicks away or app deactivates.
    panel.hidesOnDeactivate = true
    panel.standardWindowButton(.closeButton)?.isHidden = true
    panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
    panel.standardWindowButton(.zoomButton)?.isHidden = true
    // `.utilityWindow` adds a fade-in/out which read as a "delay" before
    // the palette appears. Command palettes are expected to feel instant.
    panel.animationBehavior = .none
    panel.isReleasedWhenClosed = false
    // Transparent backing - the SwiftUI palette paints the visible glass
    // card; everything outside it stays see-through so no panel chrome
    // shows.
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.contentView = makeHostingView()
    panel.onResignMain = { [weak self] in
      // resignMain fires when the user clicks elsewhere in the app or
      // switches apps. Dismiss like Spotlight.
      self?.hide()
    }
    return panel
  }

  private func makeHostingView() -> NSHostingView<OpenAnythingPaletteContent> {
    let captured = executor ?? { _ in }
    let root = OpenAnythingPaletteContent(
      model: model,
      execute: captured,
      onDismiss: { [weak self] in self?.didDismissModel() }
    )
    return NSHostingView(rootView: root)
  }

  private func positionAboveKeyWindow(_ panel: OpenAnythingFloatingPanel) {
    let anchor = NSApp.keyWindow ?? NSApp.mainWindow
    guard let anchor else {
      panel.center()
      return
    }
    let anchorFrame = anchor.frame
    let panelSize = panel.frame.size
    let x = anchorFrame.midX - panelSize.width / 2
    // Top-anchor 80pt below the host window's titlebar, matching the original
    // overlay's `topInset`.
    let y = anchorFrame.maxY - OpenAnythingPaletteConstants.topInset - panelSize.height
    panel.setFrameOrigin(NSPoint(x: x, y: y))
  }
}

/// Frame-anchored wrapper around `OpenAnythingPaletteView`. NSHostingView
/// sizes itself to the panel's content rect, and the SwiftUI body uses
/// `.ignoresSafeArea()` so the glass card paints edge-to-edge inside the
/// transparent panel.
private struct OpenAnythingPaletteContent: View {
  let model: OpenAnythingPaletteModel
  let execute: (OpenAnythingHit) -> Void
  let onDismiss: () -> Void

  var body: some View {
    OpenAnythingPaletteView(
      model: model,
      execute: execute,
      onDismiss: onDismiss
    )
    .ignoresSafeArea()
  }
}
