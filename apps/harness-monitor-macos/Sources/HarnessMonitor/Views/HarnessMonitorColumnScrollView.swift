import SwiftUI

enum HarnessMonitorColumnTopScrollEdgeEffect {
  case none
  case soft
  case hard
}

struct HarnessMonitorColumnScrollView<Content: View>: View {
  let horizontalPadding: CGFloat
  let verticalPadding: CGFloat
  let constrainContentWidth: Bool
  let readableWidth: Bool
  let topScrollEdgeEffect: HarnessMonitorColumnTopScrollEdgeEffect
  private let content: Content

  /// HIG readable content width for body text (~70 characters at body size).
  private static var readableMaxWidth: CGFloat { 680 }

  init(
    horizontalPadding: CGFloat = 24,
    verticalPadding: CGFloat = 24,
    constrainContentWidth: Bool = false,
    readableWidth: Bool = false,
    topScrollEdgeEffect: HarnessMonitorColumnTopScrollEdgeEffect = .none,
    @ViewBuilder content: () -> Content
  ) {
    self.horizontalPadding = horizontalPadding
    self.verticalPadding = verticalPadding
    self.constrainContentWidth = constrainContentWidth
    self.readableWidth = readableWidth
    self.topScrollEdgeEffect = topScrollEdgeEffect
    self.content = content()
  }

  var body: some View {
    Group {
      if constrainContentWidth || readableWidth {
        GeometryReader { geometry in
          let available = max(geometry.size.width - (horizontalPadding * 2), 0)
          let width = readableWidth ? min(available, Self.readableMaxWidth) : available
          scrollBody(contentWidth: width)
        }
      } else {
        scrollBody()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func scrollBody(contentWidth: CGFloat? = nil) -> some View {
    ScrollView {
      VStack(spacing: 0) {
        if let contentWidth {
          content
            .frame(width: contentWidth, alignment: .topLeading)
        } else {
          content
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, verticalPadding)
    }
    .modifier(TopScrollEdgeEffectModifier(effect: topScrollEdgeEffect))
  }
}

private struct TopScrollEdgeEffectModifier: ViewModifier {
  let effect: HarnessMonitorColumnTopScrollEdgeEffect

  @ViewBuilder
  func body(content: Content) -> some View {
    switch effect {
    case .none:
      content
    case .soft:
      content.scrollEdgeEffectStyle(.soft, for: .top)
    case .hard:
      content.scrollEdgeEffectStyle(.hard, for: .top)
    }
  }
}
