import AppKit
import SwiftUI
import HarnessMonitorPolicyCanvasAlgorithms

struct PolicyCanvasBackgroundSurface: NSViewRepresentable {
  func makeNSView(context: Context) -> PolicyCanvasBackgroundSurfaceView {
    PolicyCanvasBackgroundSurfaceView()
  }

  func updateNSView(_ nsView: PolicyCanvasBackgroundSurfaceView, context: Context) {}
}

@MainActor
final class PolicyCanvasBackgroundSurfaceView: NSView {
  override var isFlipped: Bool { true }
  override var isOpaque: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    policyCanvasApplyOpaqueViewportBacking(to: self)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    policyCanvasApplyOpaqueViewportBacking(to: self)
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.textBackgroundColor.setFill()
    dirtyRect.fill()
  }
}
