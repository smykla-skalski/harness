import AppKit
import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI
import os

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
  private var reviewPinProvider: ((OpenAnythingTarget) -> OpenAnythingReviewPinAction?)?
  private var panel: OpenAnythingFloatingPanel?
  private var suppressesResignMainDismissal = false
  private var lastMeasuredContentHeight: CGFloat?

  /// True when the floating panel is currently the key window. The menu
  /// presenter uses this to skip the "surface dashboard" branch on Cmd+K
  /// when we are simply re-showing an alpha-hidden panel - opening dashboard
  /// would resign the panel's main status and flap the toggle.
  var isPanelKey: Bool { panel?.isKeyWindow ?? false }
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
  func bindExecutor(
    _ executor: @escaping (OpenAnythingHit) -> Void,
    reviewPinProvider: ((OpenAnythingTarget) -> OpenAnythingReviewPinAction?)? = nil
  ) {
    self.executor = executor
    self.reviewPinProvider = reviewPinProvider
    if let panel {
      panel.contentView = makeHostingView()
    } else {
      let built = buildPanel()
      panel = built
      prewarm(built)
    }
  }

  /// Orders the panel onscreen offscreen at `alphaValue = 0` so macOS
  /// finishes the CALayer + NSHostingView first-render work AND keeps the
  /// panel registered with the WindowServer. Subsequent shows are just an
  /// alpha + position flip with no `orderFront` activation pipeline and -
  /// critically on macOS 26 - no system-level window-open fade animation,
  /// which `animationBehavior = .none` does not suppress in Tahoe (Gus
  /// Mueller, https://mastodon.social/@ccgus/115499330805867015). Raycast
  /// uses the same "keep visually hidden via alphaValue=0" pattern
  /// (https://www.raycast.com/blog/a-technical-deep-dive-into-the-new-raycast).
  private func prewarm(_ panel: OpenAnythingFloatingPanel) {
    let size = panel.frame.size
    panel.alphaValue = 0
    // Hidden panels MUST pass mouse events through - `alphaValue = 0` only
    // hides pixels, it does not disable hit-testing, so without this the
    // panel would silently swallow clicks anywhere in its frame even while
    // invisible.
    panel.ignoresMouseEvents = true
    panel.setFrame(
      NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
      display: false
    )
    panel.orderFront(nil)
    panel.displayIfNeeded()
  }

  func toggle(
    scope: OpenAnythingDomain?,
    contextDomain: OpenAnythingDomain?,
    restoreLastQuery: Bool
  ) {
    if model.isPresented {
      hide()
    } else {
      show(scope: scope, contextDomain: contextDomain, restoreLastQuery: restoreLastQuery)
    }
  }

  func show(
    scope: OpenAnythingDomain?,
    contextDomain: OpenAnythingDomain?,
    restoreLastQuery: Bool
  ) {
    let signpost = OpenAnythingSignposter.shared.beginInterval(
      OpenAnythingSignposter.Interval.present
    )
    defer {
      OpenAnythingSignposter.shared.endInterval(
        OpenAnythingSignposter.Interval.present,
        signpost
      )
    }
    let panel = panel ?? buildPanel()
    self.panel = panel
    model.present(
      targetWindowID: nil,
      scope: scope,
      contextDomain: contextDomain,
      restoreLastQuery: restoreLastQuery
    )
    sizePanelForPresentation(panel)
    positionAboveKeyWindow(panel)
    panel.alphaValue = 1
    // Re-enable hit-testing for the visible panel; prewarm/hide set this
    // to `true` so the alpha-hidden panel does not swallow clicks behind
    // its frame.
    panel.ignoresMouseEvents = false
    if panel.isVisible {
      // Pre-warmed / not yet dismissed via app-deactivate: panel is still
      // ordered front, just at alpha 0. A bare `makeKey` skips the slow
      // `orderFront` activation pipeline AND the Tahoe show animation.
      panel.makeKey()
    } else {
      // `hidesOnDeactivate = true` removed us from screen on app deactivate.
      // Fall back to the full activation path on the next show.
      panel.makeKeyAndOrderFront(nil)
    }
  }

  func hide(reason: OpenAnythingPaletteModel.DismissReason = .userCanceled) {
    guard !isClosing else { return }
    isClosing = true
    defer { isClosing = false }
    if model.isPresented {
      model.dismiss(reason: reason)
    }
    // Keep ordered front; just flip alpha + disable hit-testing so the next
    // show is instant. `ignoresMouseEvents = true` is critical - alpha=0
    // alone leaves the panel catching clicks at its frame and silently
    // hijacking pointer input from the windows behind it.
    panel?.alphaValue = 0
    panel?.ignoresMouseEvents = true
  }

  /// Called from the palette view when the model dismisses for an in-flight
  /// reason (ESC, hit executed, window resigned). Hides via alpha-flip so
  /// the panel stays warm for the next show.
  func didDismissModel() {
    guard !isClosing else { return }
    isClosing = true
    defer { isClosing = false }
    panel?.alphaValue = 0
    panel?.ignoresMouseEvents = true
  }

  func beginKeepingPanelOpenActivation() {
    suppressesResignMainDismissal = true
  }

  func endKeepingPanelOpenActivation() {
    restorePanelAfterKeepingOpenActivation()
    Task { @MainActor [weak self] in
      await Task.yield()
      self?.restorePanelAfterKeepingOpenActivation()
      self?.suppressesResignMainDismissal = false
    }
  }

  private func restorePanelAfterKeepingOpenActivation() {
    guard model.isPresented else { return }
    panel?.alphaValue = 1
    panel?.ignoresMouseEvents = false
    panel?.makeKey()
  }

  private func buildPanel() -> OpenAnythingFloatingPanel {
    let contentRect = NSRect(
      x: 0, y: 0,
      width: OpenAnythingPaletteConstants.maxWidth,
      height: OpenAnythingPaletteConstants.maxHeight
    )
    // Borderless avoids AppKit's titled-window contentLayout inset, which left
    // a dead transparent band under the SwiftUI host in palette screenshots.
    let panel = OpenAnythingFloatingPanel(
      contentRect: contentRect,
      styleMask: [.nonactivatingPanel, .borderless, .resizable],
      backing: .buffered,
      defer: false
    )
    panel.isFloatingPanel = true
    // `.statusBar` (level 25) is the canonical Spotlight-style level - above
    // any normal app window AND above the notification surface. Ardent
    // Swift's spotlight-clone recipe uses this, vs `.floating` (level 3)
    // which can be occluded by full-screen content.
    // https://ardentswift.com/posts/hotkey-window/
    panel.level = .statusBar
    // Canonical Spotlight collection behavior: float across spaces, joinable
    // in fullscreen, transient (no Mission Control thumbnail), stationary so
    // space switches do not move the panel, and ignored by Cmd-` cycle.
    panel.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .transient, .stationary, .ignoresCycle,
    ]
    panel.isMovableByWindowBackground = true
    // Spotlight-style auto-hide when the user clicks away or app deactivates.
    panel.hidesOnDeactivate = true
    // `.utilityWindow` adds a fade-in/out which read as a "delay" before
    // the palette appears. Command palettes are expected to feel instant.
    panel.animationBehavior = .none
    panel.isReleasedWhenClosed = false
    // Transparent backing - the SwiftUI palette paints the visible glass
    // card; everything outside it stays see-through so no panel chrome
    // shows.
    panel.backgroundColor = .clear
    panel.isOpaque = false
    // Disable AppKit's window auto-shadow so the fitted panel bounds stay
    // tight to the visible glass card. Open Anything intentionally renders
    // without an outer drop shadow, which keeps screenshots and reopen sizing
    // aligned with the content's actual bounds.
    panel.hasShadow = false
    panel.contentView = makeHostingView()
    panel.onResignMain = { [weak self] in
      guard self?.suppressesResignMainDismissal != true else { return }
      // resignMain fires when the user clicks elsewhere in the app or
      // switches apps. Dismiss like Spotlight.
      self?.hide(reason: .windowResignedKey)
    }
    return panel
  }

  private func makeHostingView() -> NSHostingView<OpenAnythingPaletteContent> {
    let captured = executor ?? { _ in }
    let root = OpenAnythingPaletteContent(
      model: model,
      execute: captured,
      onDismiss: { [weak self] in self?.didDismissModel() },
      onContentSizeChange: { [weak self] size in
        self?.resizePanelToContent(size)
      },
      beginKeepingPanelOpenActivation: { [weak self] in
        self?.beginKeepingPanelOpenActivation()
      },
      endKeepingPanelOpenActivation: { [weak self] in
        self?.endKeepingPanelOpenActivation()
      },
      reviewPinProvider: reviewPinProvider
    )
    let hosting = NSHostingView(rootView: root)
    // Panel size tracks the SwiftUI content via `resizePanelToContent`;
    // the hosting view itself does not need to probe for intrinsics.
    // Default `sizingOptions` of `[.minSize, .intrinsicContentSize,
    // .maxSize]` probes the rootView every view update and "comes with
    // a performance cost" per Apple's documentation.
    // https://developer.apple.com/documentation/swiftui/nshostingview/sizingoptions
    hosting.sizingOptions = []
    return hosting
  }

  /// Match the NSPanel's frame to the SwiftUI palette's measured content
  /// size, preserving the top edge so the panel grows and shrinks downward
  /// as results come and go. Mirrors Raycast/Spotlight where the floating
  /// card visibly resizes as the user types.
  private func resizePanelToContent(_ size: CGSize) {
    guard let panel else { return }
    guard size.width > 0, let clampedHeight = clampedContentHeight(size.height) else {
      return
    }
    lastMeasuredContentHeight = clampedHeight
    resizePanel(panel, toContentHeight: clampedHeight, preservesTopEdge: true)
  }

  private func sizePanelForPresentation(_ panel: OpenAnythingFloatingPanel) {
    if let lastMeasuredContentHeight {
      resizePanel(
        panel,
        toContentHeight: lastMeasuredContentHeight,
        preservesTopEdge: false
      )
      return
    }
    sizePanelToFittingContent(panel)
  }

  /// Force the hidden/prewarmed panel to match the SwiftUI content's fitting
  /// height before we position or reveal it. That keeps the first visible frame
  /// aligned with every subsequent reopen and avoids screenshotting the old
  /// prewarm height below the footer.
  private func sizePanelToFittingContent(_ panel: OpenAnythingFloatingPanel) {
    guard let contentView = panel.contentView else { return }
    contentView.layoutSubtreeIfNeeded()
    contentView.displayIfNeeded()
    guard let fittingHeight = clampedContentHeight(contentView.fittingSize.height) else {
      return
    }
    lastMeasuredContentHeight = fittingHeight
    resizePanel(panel, toContentHeight: fittingHeight, preservesTopEdge: false)
  }

  private func clampedContentHeight(_ height: CGFloat) -> CGFloat? {
    let clampedHeight = min(height, OpenAnythingPaletteConstants.maxHeight)
    guard clampedHeight.isFinite, clampedHeight > 0 else { return nil }
    return clampedHeight
  }

  private func resizePanel(
    _ panel: OpenAnythingFloatingPanel,
    toContentHeight contentHeight: CGFloat,
    preservesTopEdge: Bool
  ) {
    guard abs(panel.frame.height - contentHeight) >= 0.5 else { return }
    var frame = panel.frame
    let topEdge = frame.maxY
    frame.size.height = contentHeight
    if preservesTopEdge {
      frame.origin.y = topEdge - contentHeight
    }
    panel.setFrame(frame, display: false, animate: false)
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
  let onContentSizeChange: (CGSize) -> Void
  let beginKeepingPanelOpenActivation: () -> Void
  let endKeepingPanelOpenActivation: () -> Void
  let reviewPinProvider: ((OpenAnythingTarget) -> OpenAnythingReviewPinAction?)?

  var body: some View {
    OpenAnythingPaletteView(
      model: model,
      execute: execute,
      onDismiss: onDismiss,
      onContentSizeChange: onContentSizeChange,
      beginKeepingPanelOpenActivation: beginKeepingPanelOpenActivation,
      endKeepingPanelOpenActivation: endKeepingPanelOpenActivation,
      reviewPinProvider: reviewPinProvider
    )
    .ignoresSafeArea()
  }
}
