import AppKit
import HarnessMonitorKit

extension OpenAnythingPaletteWindowController {
  /// Place the panel on show. Restores the user's remembered origin (clamped
  /// back onto a live screen) when one exists, otherwise centers on the active
  /// screen. Wrapped in `withProgrammaticFrameAdjustment` so the move observer
  /// does not record this placement as a user drag.
  func positionPanel(_ panel: OpenAnythingFloatingPanel) {
    let origin = OpenAnythingPanelPlacement.resolvedOrigin(
      savedOrigin: savedPanelOrigin(),
      panelSize: panel.frame.size,
      visibleFrames: NSScreen.screens.map(\.visibleFrame),
      defaultVisibleFrame: defaultPlacementVisibleFrame(excluding: panel)
    )
    withProgrammaticFrameAdjustment {
      panel.setFrameOrigin(origin)
    }
  }

  /// Visible frame of the screen the palette centers on when there is no
  /// remembered origin: the active window's screen, then the screen under the
  /// pointer, then the main screen.
  private func defaultPlacementVisibleFrame(excluding panel: NSWindow) -> CGRect {
    if let screen = bestAnchorWindow(excluding: panel)?.screen {
      return screen.visibleFrame
    }
    let pointer = NSEvent.mouseLocation
    if let pointerScreen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) {
      return pointerScreen.visibleFrame
    }
    return (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
  }

  private func bestAnchorWindow(excluding panel: NSWindow) -> NSWindow? {
    if let key = NSApp.keyWindow, key !== panel { return key }
    if let main = NSApp.mainWindow, main !== panel { return main }
    return NSApp.windows.first { window in
      window !== panel
        && window.isVisible
        && window.styleMask.contains(.titled)
        && !window.isExcludedFromWindowsMenu
    }
  }

  /// `NSWindowDelegate` hook: remember the panel origin whenever the user drags
  /// it. Programmatic moves (prewarm, resize-to-content, centering) are skipped
  /// via `isAdjustingFrameProgrammatically`, so only a real drag is persisted.
  @objc
  func windowDidMove(_ notification: Notification) {
    guard
      !isAdjustingFrameProgrammatically,
      let window = notification.object as? NSWindow
    else {
      return
    }
    persistPanelOrigin(window.frame.origin)
  }

  private func savedPanelOrigin() -> CGPoint? {
    guard
      let raw = UserDefaults.standard.string(
        forKey: OpenAnythingPreferencesDefaults.windowFrameOriginKey
      ),
      !raw.isEmpty
    else {
      return nil
    }
    return NSPointFromString(raw)
  }

  private func persistPanelOrigin(_ origin: CGPoint) {
    UserDefaults.standard.set(
      NSStringFromPoint(origin),
      forKey: OpenAnythingPreferencesDefaults.windowFrameOriginKey
    )
  }
}
