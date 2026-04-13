import AppKit
import SwiftUI

// MARK: - Configuration

public enum SmartZoomConfiguration {
  public static let zoomScale: CGFloat = 2.0
  public static let animationDuration: TimeInterval = 0.3

  public static func effectiveScale(isActive: Bool) -> CGFloat {
    isActive ? zoomScale : 1.0
  }
}

// MARK: - Modifier

public struct SmartZoomModifier: ViewModifier {
  @State private var isZoomed = false

  public init() {}

  public func body(content: Content) -> some View {
    content
      .scaleEffect(SmartZoomConfiguration.effectiveScale(isActive: isZoomed), anchor: .center)
      .animation(.spring(duration: SmartZoomConfiguration.animationDuration), value: isZoomed)
      .background(SmartZoomConfigurator(isZoomed: $isZoomed))
  }
}

extension View {
  public func smartZoom() -> some View {
    modifier(SmartZoomModifier())
  }
}

// MARK: - AppKit bridge

private struct SmartZoomConfigurator: NSViewRepresentable {
  @Binding var isZoomed: Bool

  func makeNSView(context: Context) -> NSView {
    let view = SmartZoomDetectorView()
    view.alphaValue = 0
    view.setAccessibilityHidden(true)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    guard let detectorView = nsView as? SmartZoomDetectorView else { return }
    detectorView.onSmartZoom = { [self] in
      isZoomed.toggle()
    }
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
    guard let detectorView = nsView as? SmartZoomDetectorView else { return }
    detectorView.removeEventMonitor()
  }
}

private final class SmartZoomDetectorView: NSView {
  var onSmartZoom: (() -> Void)?
  private var eventMonitor: Any?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil {
      installEventMonitor()
    } else {
      removeEventMonitor()
    }
  }

  func removeEventMonitor() {
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
    }
    eventMonitor = nil
  }

  private func installEventMonitor() {
    guard eventMonitor == nil else { return }
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .smartMagnify) {
      [weak self] event in
      guard let self, event.window == self.window else { return event }
      self.onSmartZoom?()
      return event
    }
  }
}
