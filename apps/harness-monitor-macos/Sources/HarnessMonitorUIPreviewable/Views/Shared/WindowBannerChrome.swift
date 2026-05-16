import SwiftUI

public struct WindowBannerChrome<Content: View, Banners: View>: View {
  let windowID: String
  let isPresented: Bool
  let publishesStateMarker: Bool
  let content: Content
  let banners: Banners

  public init(
    windowID: String,
    isPresented: Bool,
    publishesStateMarker: Bool = true,
    @ViewBuilder content: () -> Content,
    @ViewBuilder banners: () -> Banners
  ) {
    self.windowID = windowID
    self.isPresented = isPresented
    self.publishesStateMarker = publishesStateMarker
    self.content = content()
    self.banners = banners()
  }

  public var body: some View {
    content
      .safeAreaInset(edge: .top, spacing: 0) {
        if isPresented {
          banners
            .background { WindowBannerChromeBackground() }
            .overlay { chromeContainerMarker }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .overlay { chromeStateMarker }
  }

  @ViewBuilder private var chromeContainerMarker: some View {
    if HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled {
      WindowBannerChromeTextMarker(
        identifier: HarnessMonitorAccessibility.windowBannerChrome(windowID),
        text: "windowID=\(windowID), chrome=shared"
      )
    }
  }

  @ViewBuilder private var chromeStateMarker: some View {
    if publishesStateMarker, HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled {
      WindowBannerChromeTextMarker(
        identifier: HarnessMonitorAccessibility.windowBannerChromeState(windowID),
        text: [
          "windowID=\(windowID)",
          "chrome=shared",
          "placement=safeAreaTop",
          "material=softWindowBackground",
          "divider=shared",
          "visible=\(isPresented ? "true" : "false")",
        ].joined(separator: ", ")
      )
    }
  }
}

private struct WindowBannerChromeBackground: View {
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  var body: some View {
    Color(nsColor: .windowBackgroundColor)
      .opacity(opacity)
      .accessibilityHidden(true)
  }

  private var opacity: Double {
    if reduceTransparency {
      return 1.0
    }
    return colorSchemeContrast == .increased ? 0.94 : 0.78
  }
}

private struct WindowBannerChromeTextMarker: View {
  let identifier: String
  let text: String

  var body: some View {
    Color.clear
      .frame(width: 1, height: 1)
      .allowsHitTesting(false)
      .accessibilityElement()
      .accessibilityLabel(text)
      .accessibilityIdentifier(identifier)
  }
}

public struct WindowBannerDivider: View {
  let tint: Color

  public init(tint: Color) {
    self.tint = tint
  }

  public var body: some View {
    Rectangle()
      .fill(tint.opacity(0.35))
      .frame(height: 1)
      .accessibilityHidden(true)
  }
}
