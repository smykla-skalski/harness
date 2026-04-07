import SwiftUI

struct HarnessCornerOverlayConfiguration {
  var width: CGFloat = 280
  var height: CGFloat? = nil
  var edgePadding: CGFloat = HarnessMonitorTheme.spacingLG
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
          .padding(configuration.edgePadding)
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
      .padding(HarnessMonitorTheme.cardPadding)
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

  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast
  @Environment(\.colorScheme)
  private var colorScheme

  func body(content: Content) -> some View {
    if appliesGlass {
      content
        .harnessFloatingControlGlass(
          cornerRadius: cornerRadius,
          prominence: prominence
        )
    } else {
      content
        .background {
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(opaqueFallbackColor)
        }
        .overlay {
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
              borderColor,
              lineWidth: colorSchemeContrast == .increased ? 1.5 : 1
            )
        }
    }
  }

  private var opaqueFallbackColor: Color {
    Color(nsColor: .windowBackgroundColor)
      .opacity(colorScheme == .dark ? 0.92 : 0.96)
  }

  private var borderColor: Color {
    HarnessMonitorTheme.controlBorder
      .opacity(colorSchemeContrast == .increased ? 0.42 : 0.24)
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
