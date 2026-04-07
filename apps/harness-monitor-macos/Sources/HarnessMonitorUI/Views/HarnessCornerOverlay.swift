import SwiftUI

struct HarnessCornerOverlayConfiguration {
  var width: CGFloat = 280
  var height: CGFloat? = nil
  var trailingPadding: CGFloat = HarnessMonitorTheme.spacingLG
  var bottomPadding: CGFloat = HarnessMonitorTheme.spacingLG
  var contentPadding: CGFloat = HarnessMonitorTheme.cardPadding
  var cornerRadius: CGFloat = HarnessMonitorTheme.cornerRadiusMD
  var appliesGlass: Bool = true
  var glassProminence: HarnessMonitorFloatingGlassProminence = .regular
  var accessibilityLabel: String = "Overlay"
  var accessibilityIdentifier: String = HarnessMonitorAccessibility.cornerOverlay
}

struct HarnessCornerOverlayModifier<OverlayContent: View>: ViewModifier {
  let isPresented: Bool
  let configuration: HarnessCornerOverlayConfiguration
  let overlayContent: OverlayContent

  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  init(
    isPresented: Bool,
    configuration: HarnessCornerOverlayConfiguration = .init(),
    @ViewBuilder overlayContent: () -> OverlayContent
  ) {
    self.isPresented = isPresented
    self.configuration = configuration
    self.overlayContent = overlayContent()
  }

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .bottomTrailing) {
        if isPresented {
          HarnessCornerOverlayContainer(
            configuration: configuration,
            content: overlayContent
          )
          .contentShape(
            .interaction,
            RoundedRectangle(cornerRadius: configuration.cornerRadius, style: .continuous)
          )
          .padding(.trailing, configuration.trailingPadding)
          .padding(.bottom, configuration.bottomPadding)
          .transition(reduceMotion ? .opacity : overlayTransition)
        }
      }
      .animation(
        .spring(duration: 0.35, bounce: 0.15),
        value: isPresented
      )
  }

  private var overlayTransition: AnyTransition {
    .asymmetric(
      insertion: .move(edge: .trailing).combined(with: .opacity),
      removal: .opacity
    )
  }
}

private struct HarnessCornerOverlayContainer<Content: View>: View {
  let configuration: HarnessCornerOverlayConfiguration
  let content: Content

  var body: some View {
    content
      .frame(width: configuration.width)
      .frame(height: configuration.height)
      .padding(configuration.contentPadding)
      .modifier(
        HarnessCornerOverlaySurfaceModifier(
          cornerRadius: configuration.cornerRadius,
          appliesGlass: configuration.appliesGlass,
          prominence: configuration.glassProminence
        )
      )
      .accessibilityElement(children: .contain)
      .accessibilityLabel(configuration.accessibilityLabel)
      .accessibilityIdentifier(configuration.accessibilityIdentifier)
  }
}

private struct HarnessCornerOverlaySurfaceModifier: ViewModifier {
  let cornerRadius: CGFloat
  let appliesGlass: Bool
  let prominence: HarnessMonitorFloatingGlassProminence

  func body(content: Content) -> some View {
    if appliesGlass {
      content
        .harnessFloatingControlGlass(
          cornerRadius: cornerRadius,
          prominence: prominence
        )
    } else {
      content
    }
  }

}

extension View {
  func harnessCornerOverlay<C: View>(
    isPresented: Bool,
    configuration: HarnessCornerOverlayConfiguration = .init(),
    @ViewBuilder content: () -> C
  ) -> some View {
    modifier(
      HarnessCornerOverlayModifier(
        isPresented: isPresented,
        configuration: configuration,
        overlayContent: content
      )
    )
  }
}
