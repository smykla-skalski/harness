import SwiftUI

extension View {
  func harnessMonitorListChrome() -> some View {
    contentMargins(.bottom, 96, for: .scrollContent)
      .toolbarBackground(.visible, for: .navigationBar)
  }

  func harnessActionButtonStyle(prominent: Bool = false, tint: Color? = nil) -> some View {
    modifier(HarnessActionButtonModifier(prominent: prominent, tint: tint))
  }

  func harnessStatusBadge(_ color: Color) -> some View {
    modifier(HarnessStatusBadgeModifier(color: color))
  }

  func harnessBalancedListSeparator() -> some View {
    alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
      .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
        dimensions.width
      }
  }
}

private struct HarnessActionButtonModifier: ViewModifier {
  let prominent: Bool
  let tint: Color?

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
    .controlSize(.regular)
    .buttonBorderShape(.capsule)
    .labelStyle(HarnessCompactActionLabelStyle())
    .font(.caption.weight(.semibold))
    .tint(tint)
    .fixedSize(horizontal: true, vertical: true)
  }
}

private struct HarnessCompactActionLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 3) {
      configuration.icon
      configuration.title
    }
  }
}

private struct HarnessStatusBadgeModifier: ViewModifier {
  let color: Color

  func body(content: Content) -> some View {
    content
      .font(.caption2.weight(.semibold))
      .foregroundStyle(color)
      .lineLimit(1)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(color.opacity(0.12), in: Capsule())
  }
}

struct HarnessCompactIconText: View {
  let title: String
  let systemImage: String
  var spacing: CGFloat = 4

  var body: some View {
    HStack(spacing: spacing) {
      Image(systemName: systemImage)
        .imageScale(.medium)
      Text(title)
    }
  }
}
