import SwiftUI

extension View {
  func harnessMonitorListChrome() -> some View {
    contentMargins(.bottom, 96, for: .scrollContent)
  }

  func harnessActionButtonStyle(prominent: Bool = false) -> some View {
    modifier(HarnessActionButtonModifier(prominent: prominent))
  }
}

private struct HarnessActionButtonModifier: ViewModifier {
  let prominent: Bool

  func body(content: Content) -> some View {
    Group {
      if #available(iOS 26.0, *) {
        if prominent {
          content.buttonStyle(.glassProminent)
        } else {
          content.buttonStyle(.glass)
        }
      } else if prominent {
        content.buttonStyle(.borderedProminent)
      } else {
        content.buttonStyle(.bordered)
      }
    }
    .controlSize(.small)
    .buttonBorderShape(.capsule)
    .labelStyle(.titleAndIcon)
    .font(.caption.weight(.semibold))
    .fixedSize(horizontal: true, vertical: true)
  }
}
