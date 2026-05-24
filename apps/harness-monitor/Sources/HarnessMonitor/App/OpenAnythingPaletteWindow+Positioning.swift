import AppKit
import HarnessMonitorUIPreviewable

extension OpenAnythingPaletteWindowController {
  func positionAboveKeyWindow(_ panel: OpenAnythingFloatingPanel) {
    let anchor = bestAnchorWindow(excluding: panel)
    guard let anchor else {
      panel.center()
      return
    }
    let origin = clampedPanelOrigin(
      panelSize: panel.frame.size,
      anchorFrame: anchor.frame,
      visibleFrame: (anchor.screen ?? NSScreen.main)?.visibleFrame
    )
    panel.setFrameOrigin(origin)
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

  private func clampedPanelOrigin(
    panelSize: NSSize,
    anchorFrame: NSRect,
    visibleFrame: NSRect?
  ) -> NSPoint {
    let preferred = NSPoint(
      x: anchorFrame.midX - panelSize.width / 2,
      y: anchorFrame.maxY - OpenAnythingPaletteConstants.topInset - panelSize.height
    )
    guard let visibleFrame else { return preferred }
    return NSPoint(
      x: clamp(
        preferred.x,
        lowerBound: visibleFrame.minX + Self.screenInset,
        upperBound: visibleFrame.maxX - panelSize.width - Self.screenInset,
        fallback: visibleFrame.midX - panelSize.width / 2
      ),
      y: clamp(
        preferred.y,
        lowerBound: visibleFrame.minY + Self.screenInset,
        upperBound: visibleFrame.maxY - panelSize.height - Self.screenInset,
        fallback: visibleFrame.midY - panelSize.height / 2
      )
    )
  }

  private func clamp(
    _ value: CGFloat,
    lowerBound: CGFloat,
    upperBound: CGFloat,
    fallback: CGFloat
  ) -> CGFloat {
    guard lowerBound <= upperBound else { return fallback }
    return min(max(value, lowerBound), upperBound)
  }

  private static let screenInset: CGFloat = 12
}
