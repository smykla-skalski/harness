import AppKit
import SwiftUI

extension View {
  func suppressNativeFocusRing() -> some View {
    background(SessionContentDetailFocusRingSuppressor())
  }
}

private struct SessionContentDetailFocusRingSuppressor: NSViewRepresentable {
  final class HostView: NSView {
    override var focusRingType: NSFocusRingType {
      get { .none }
      set {}
    }
  }

  func makeNSView(context: Context) -> HostView {
    HostView()
  }

  func updateNSView(_ nsView: HostView, context: Context) {}
}
