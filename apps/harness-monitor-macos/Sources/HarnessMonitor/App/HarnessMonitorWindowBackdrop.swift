import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct HarnessMonitorWindowBackdropModifier: ViewModifier {
  let mode: HarnessMonitorBackdropMode
  let backgroundImage: HarnessMonitorBackgroundSelection

  @ViewBuilder
  func body(content: Content) -> some View {
    switch mode {
    case .none:
      content
    case .window:
      content.containerBackground(for: .window) {
        HarnessMonitorWindowBackdropView(backgroundImage: backgroundImage)
      }
    case .content:
      content.background {
        HarnessMonitorWindowBackdropView(backgroundImage: backgroundImage)
      }
    }
  }
}

struct HarnessMonitorWindowBackdropView: View {
  let backgroundImage: HarnessMonitorBackgroundSelection
  @Environment(\.colorScheme)
  private var colorScheme
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @State private var loadedImage: Image?

  private var baseBackground: Color {
    Color(nsColor: .windowBackgroundColor)
  }

  private var topScrimOpacity: Double {
    if reduceTransparency {
      return colorScheme == .dark ? 0.28 : 0.16
    }
    return colorScheme == .dark ? 0.18 : 0.08
  }

  private var successGlowOpacity: Double {
    if reduceTransparency {
      return colorScheme == .dark ? 0.12 : 0.09
    }
    return colorScheme == .dark ? 0.09 : 0.06
  }

  private var accentGlowOpacity: Double {
    if reduceTransparency {
      return colorScheme == .dark ? 0.10 : 0.08
    }
    return colorScheme == .dark ? 0.07 : 0.05
  }

  private var imageWashOpacity: Double {
    if reduceTransparency {
      return colorScheme == .dark ? 0.54 : 0.42
    }
    return colorScheme == .dark ? 0.24 : 0.16
  }

  private var imageOpacity: Double {
    if reduceTransparency {
      return colorScheme == .dark ? 0.56 : 0.48
    }
    return colorScheme == .dark ? 0.94 : 0.86
  }

  private var blurRadius: CGFloat {
    reduceTransparency ? 0 : 10
  }

  var body: some View {
    ZStack {
      if let loadedImage {
        loadedImage
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fill)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .scaleEffect(1.03)
          .saturation(colorScheme == .dark ? 1.0 : 0.9)
          .contrast(colorScheme == .dark ? 1.02 : 0.98)
          .opacity(imageOpacity)
          .blur(radius: blurRadius)
      }

      LinearGradient(
        colors: [
          baseBackground,
          baseBackground,
          HarnessMonitorTheme.ink.opacity(colorScheme == .dark ? 0.08 : 0.03),
        ],
        startPoint: .top,
        endPoint: .bottom
      )

      Rectangle()
        .fill(baseBackground.opacity(imageWashOpacity))

      RadialGradient(
        colors: [
          HarnessMonitorTheme.success.opacity(successGlowOpacity),
          .clear,
        ],
        center: .topLeading,
        startRadius: 24,
        endRadius: 560
      )

      RadialGradient(
        colors: [
          HarnessMonitorTheme.accent.opacity(accentGlowOpacity),
          .clear,
        ],
        center: .bottomTrailing,
        startRadius: 40,
        endRadius: 620
      )

      LinearGradient(
        colors: [
          HarnessMonitorTheme.overlayScrim.opacity(topScrimOpacity),
          .clear,
        ],
        startPoint: .top,
        endPoint: .bottom
      )
    }
    .ignoresSafeArea()
    .accessibilityHidden(true)
    .task(id: backgroundImage.storageValue) {
      loadedImage = nil
      guard
        let cgImage = await BackgroundThumbnailCache.shared.fullImage(
          for: backgroundImage
        )
      else {
        return
      }
      loadedImage = Image(decorative: cgImage, scale: 1.0)
    }
  }
}
