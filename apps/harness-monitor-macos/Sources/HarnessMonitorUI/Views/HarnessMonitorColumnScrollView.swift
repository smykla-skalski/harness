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
  private let underlay: AnyView?
  private let overlay: AnyView?

  /// HIG readable content width for body text (~70 characters at body size).
  private static var readableMaxWidth: CGFloat { 680 }

  init(
    horizontalPadding: CGFloat = 24,
    verticalPadding: CGFloat = 24,
    constrainContentWidth: Bool = false,
    readableWidth: Bool = false,
    topScrollEdgeEffect: HarnessMonitorColumnTopScrollEdgeEffect = .soft,
    @ViewBuilder content: () -> Content
  ) {
    self.horizontalPadding = horizontalPadding
    self.verticalPadding = verticalPadding
    self.constrainContentWidth = constrainContentWidth
    self.readableWidth = readableWidth
    self.topScrollEdgeEffect = topScrollEdgeEffect
    self.content = content()
    underlay = nil
    overlay = nil
  }

  init<Underlay: View>(
    horizontalPadding: CGFloat = 24,
    verticalPadding: CGFloat = 24,
    constrainContentWidth: Bool = false,
    readableWidth: Bool = false,
    topScrollEdgeEffect: HarnessMonitorColumnTopScrollEdgeEffect = .soft,
    @ViewBuilder underlay: () -> Underlay,
    @ViewBuilder content: () -> Content
  ) {
    self.horizontalPadding = horizontalPadding
    self.verticalPadding = verticalPadding
    self.constrainContentWidth = constrainContentWidth
    self.readableWidth = readableWidth
    self.topScrollEdgeEffect = topScrollEdgeEffect
    self.content = content()
    self.underlay = AnyView(underlay())
    overlay = nil
  }

  init<Underlay: View, Overlay: View>(
    horizontalPadding: CGFloat = 24,
    verticalPadding: CGFloat = 24,
    constrainContentWidth: Bool = false,
    readableWidth: Bool = false,
    topScrollEdgeEffect: HarnessMonitorColumnTopScrollEdgeEffect = .soft,
    @ViewBuilder underlay: () -> Underlay,
    @ViewBuilder overlay: () -> Overlay,
    @ViewBuilder content: () -> Content
  ) {
    self.horizontalPadding = horizontalPadding
    self.verticalPadding = verticalPadding
    self.constrainContentWidth = constrainContentWidth
    self.readableWidth = readableWidth
    self.topScrollEdgeEffect = topScrollEdgeEffect
    self.content = content()
    self.underlay = AnyView(underlay())
    self.overlay = AnyView(overlay())
  }

  var body: some View {
    Group {
      if readableWidth {
        GeometryReader { geometry in
          let available = max(geometry.size.width - (horizontalPadding * 2), 0)
          scrollBody(contentWidth: min(available, Self.readableMaxWidth))
        }
      } else {
        scrollBody()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func scrollBody(contentWidth: CGFloat? = nil) -> some View {
    ScrollView {
      ZStack(alignment: .topLeading) {
        if let underlay {
          underlay
        }

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

        if let overlay {
          overlay
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .scrollClipDisabled(underlay != nil)
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
