import SwiftUI

public enum HarnessMonitorColumnTopScrollEdgeEffect {
  case none
  case soft
  case hard
}

public struct HarnessMonitorColumnScrollView<
  Content: View, Underlay: View, Overlay: View, BottomInset: View
>: View {
  public let horizontalPadding: CGFloat
  public let verticalPadding: CGFloat
  public let constrainContentWidth: Bool
  public let readableWidth: Bool
  public let topScrollEdgeEffect: HarnessMonitorColumnTopScrollEdgeEffect
  public let bottomScrollContentMargin: CGFloat
  public let bottomInsetSpacing: CGFloat
  public let scrollSurfaceIdentifier: String?
  public let scrollSurfaceLabel: String?
  private let externalScrollPosition: Binding<ScrollPosition>?
  private let content: Content
  private let underlay: Underlay?
  private let overlay: Overlay?
  private let bottomInset: BottomInset?

  /// HIG readable content width for body text (~70 characters at body size).
  private static var readableMaxWidth: CGFloat { 680 }

  public init(
    horizontalPadding: CGFloat,
    verticalPadding: CGFloat,
    constrainContentWidth: Bool,
    readableWidth: Bool,
    topScrollEdgeEffect: HarnessMonitorColumnTopScrollEdgeEffect,
    bottomScrollContentMargin: CGFloat = 0,
    scrollSurfaceIdentifier: String? = nil,
    scrollSurfaceLabel: String? = nil,
    scrollPosition: Binding<ScrollPosition>? = nil,
    @ViewBuilder content: () -> Content
  ) where Underlay == EmptyView, Overlay == EmptyView, BottomInset == EmptyView {
    self.horizontalPadding = horizontalPadding
    self.verticalPadding = verticalPadding
    self.constrainContentWidth = constrainContentWidth
    self.readableWidth = readableWidth
    self.topScrollEdgeEffect = topScrollEdgeEffect
    self.bottomScrollContentMargin = bottomScrollContentMargin
    bottomInsetSpacing = 0
    self.scrollSurfaceIdentifier = scrollSurfaceIdentifier
    self.scrollSurfaceLabel = scrollSurfaceLabel
    externalScrollPosition = scrollPosition
    self.content = content()
    underlay = nil
    overlay = nil
    bottomInset = nil
  }

  public init(
    horizontalPadding: CGFloat,
    verticalPadding: CGFloat,
    constrainContentWidth: Bool,
    readableWidth: Bool,
    topScrollEdgeEffect: HarnessMonitorColumnTopScrollEdgeEffect,
    bottomScrollContentMargin: CGFloat = 0,
    bottomInsetSpacing: CGFloat = 0,
    scrollSurfaceIdentifier: String? = nil,
    scrollSurfaceLabel: String? = nil,
    scrollPosition: Binding<ScrollPosition>? = nil,
    @ViewBuilder bottomInset: () -> BottomInset,
    @ViewBuilder content: () -> Content
  ) where Underlay == EmptyView, Overlay == EmptyView {
    self.horizontalPadding = horizontalPadding
    self.verticalPadding = verticalPadding
    self.constrainContentWidth = constrainContentWidth
    self.readableWidth = readableWidth
    self.topScrollEdgeEffect = topScrollEdgeEffect
    self.bottomScrollContentMargin = bottomScrollContentMargin
    self.bottomInsetSpacing = bottomInsetSpacing
    self.scrollSurfaceIdentifier = scrollSurfaceIdentifier
    self.scrollSurfaceLabel = scrollSurfaceLabel
    externalScrollPosition = scrollPosition
    self.content = content()
    underlay = nil
    overlay = nil
    self.bottomInset = bottomInset()
  }

  public init(
    horizontalPadding: CGFloat,
    verticalPadding: CGFloat,
    constrainContentWidth: Bool,
    readableWidth: Bool,
    topScrollEdgeEffect: HarnessMonitorColumnTopScrollEdgeEffect,
    bottomScrollContentMargin: CGFloat = 0,
    scrollSurfaceIdentifier: String? = nil,
    scrollSurfaceLabel: String? = nil,
    scrollPosition: Binding<ScrollPosition>? = nil,
    @ViewBuilder underlay: () -> Underlay,
    @ViewBuilder content: () -> Content
  ) where Overlay == EmptyView, BottomInset == EmptyView {
    self.horizontalPadding = horizontalPadding
    self.verticalPadding = verticalPadding
    self.constrainContentWidth = constrainContentWidth
    self.readableWidth = readableWidth
    self.topScrollEdgeEffect = topScrollEdgeEffect
    self.bottomScrollContentMargin = bottomScrollContentMargin
    bottomInsetSpacing = 0
    self.scrollSurfaceIdentifier = scrollSurfaceIdentifier
    self.scrollSurfaceLabel = scrollSurfaceLabel
    externalScrollPosition = scrollPosition
    self.content = content()
    self.underlay = underlay()
    overlay = nil
    bottomInset = nil
  }

  public init(
    horizontalPadding: CGFloat,
    verticalPadding: CGFloat,
    constrainContentWidth: Bool,
    readableWidth: Bool,
    topScrollEdgeEffect: HarnessMonitorColumnTopScrollEdgeEffect,
    bottomScrollContentMargin: CGFloat = 0,
    scrollSurfaceIdentifier: String? = nil,
    scrollSurfaceLabel: String? = nil,
    scrollPosition: Binding<ScrollPosition>? = nil,
    @ViewBuilder overlay: () -> Overlay,
    @ViewBuilder content: () -> Content
  ) where Underlay == EmptyView, BottomInset == EmptyView {
    self.horizontalPadding = horizontalPadding
    self.verticalPadding = verticalPadding
    self.constrainContentWidth = constrainContentWidth
    self.readableWidth = readableWidth
    self.topScrollEdgeEffect = topScrollEdgeEffect
    self.bottomScrollContentMargin = bottomScrollContentMargin
    bottomInsetSpacing = 0
    self.scrollSurfaceIdentifier = scrollSurfaceIdentifier
    self.scrollSurfaceLabel = scrollSurfaceLabel
    externalScrollPosition = scrollPosition
    self.content = content()
    underlay = nil
    self.overlay = overlay()
    bottomInset = nil
  }

  public init(
    horizontalPadding: CGFloat,
    verticalPadding: CGFloat,
    constrainContentWidth: Bool,
    readableWidth: Bool,
    topScrollEdgeEffect: HarnessMonitorColumnTopScrollEdgeEffect,
    bottomScrollContentMargin: CGFloat = 0,
    scrollSurfaceIdentifier: String? = nil,
    scrollSurfaceLabel: String? = nil,
    scrollPosition: Binding<ScrollPosition>? = nil,
    @ViewBuilder underlay: () -> Underlay,
    @ViewBuilder overlay: () -> Overlay,
    @ViewBuilder content: () -> Content
  ) where BottomInset == EmptyView {
    self.horizontalPadding = horizontalPadding
    self.verticalPadding = verticalPadding
    self.constrainContentWidth = constrainContentWidth
    self.readableWidth = readableWidth
    self.topScrollEdgeEffect = topScrollEdgeEffect
    self.bottomScrollContentMargin = bottomScrollContentMargin
    bottomInsetSpacing = 0
    self.scrollSurfaceIdentifier = scrollSurfaceIdentifier
    self.scrollSurfaceLabel = scrollSurfaceLabel
    externalScrollPosition = scrollPosition
    self.content = content()
    self.underlay = underlay()
    self.overlay = overlay()
    bottomInset = nil
  }

  public var body: some View {
    Group {
      if readableWidth || constrainContentWidth {
        GeometryReader { geometry in
          let available = max(geometry.size.width - (horizontalPadding * 2), 0)
          scrollBody(contentWidth: resolvedContentWidth(availableWidth: available))
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
    .contentMargins(.bottom, bottomScrollContentMargin, for: .scrollContent)
    .modifier(TopScrollEdgeEffectModifier(effect: topScrollEdgeEffect))
    .modifier(ExternalScrollPositionModifier(binding: externalScrollPosition))
    .harnessPrimaryContentScrollSurface(
      listIdentifier: scrollSurfaceIdentifier,
      listLabel: scrollSurfaceLabel
    )
    .modifier(BottomScrollInsetModifier(spacing: bottomInsetSpacing, inset: bottomInset))
  }

  private func resolvedContentWidth(availableWidth: CGFloat) -> CGFloat {
    if readableWidth {
      return min(availableWidth, Self.readableMaxWidth)
    }
    return availableWidth
  }
}

private struct BottomScrollInsetModifier<Inset: View>: ViewModifier {
  let spacing: CGFloat
  let inset: Inset?

  @ViewBuilder
  func body(content: Content) -> some View {
    if let inset {
      content.safeAreaInset(edge: .bottom, spacing: spacing) {
        inset
      }
    } else {
      content
    }
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
      content.scrollEdgeEffectStyle(.soft, for: .top)
    }
  }
}

/// Applies `.scrollPosition` only when the caller supplied a binding so the shared
/// scroll-view stays inert for the common case while perf scenarios opt in.
private struct ExternalScrollPositionModifier: ViewModifier {
  let binding: Binding<ScrollPosition>?

  @ViewBuilder
  func body(content: Content) -> some View {
    if let binding {
      content.scrollPosition(binding)
    } else {
      content
    }
  }
}
