import HarnessMonitorKit
import SwiftUI

public struct WindowToolbarBackdropModel: Equatable, Sendable {
  public enum Tone: Equatable, Sendable {
    case dashboardTaskBoard
    case dashboardPolicyCanvas
    case session(SessionStatus, isStale: Bool)
  }

  let tone: Tone
  let intensity: Double

  public init(tone: Tone, intensity: Double = 1.0) {
    self.tone = tone
    self.intensity = min(max(intensity, 0), 1)
  }

  public static func dashboardTaskBoard() -> WindowToolbarBackdropModel {
    WindowToolbarBackdropModel(tone: .dashboardTaskBoard, intensity: 0.82)
  }

  public static func dashboardPolicyCanvas() -> WindowToolbarBackdropModel {
    WindowToolbarBackdropModel(tone: .dashboardPolicyCanvas, intensity: 0.78)
  }

  public static func session(
    status: SessionStatus,
    isStale: Bool
  ) -> WindowToolbarBackdropModel {
    WindowToolbarBackdropModel(
      tone: .session(status, isStale: isStale),
      intensity: isStale ? 0.52 : 0.72
    )
  }
}

extension View {
  public func windowToolbarBackdropUnderlay(
    _ model: WindowToolbarBackdropModel
  ) -> some View {
    background(alignment: .top) {
      WindowToolbarBackdropUnderlay(model: model)
    }
  }
}

public struct WindowToolbarBackdropUnderlay: View {
  private static let height: CGFloat = 176

  let model: WindowToolbarBackdropModel

  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  public init(model: WindowToolbarBackdropModel) {
    self.model = model
  }

  public var body: some View {
    if shouldRender {
      ZStack(alignment: .topLeading) {
        LinearGradient(
          colors: [
            primaryColor.opacity(topOpacity),
            secondaryColor.opacity(midOpacity),
            primaryColor.opacity(bottomOpacity),
            .clear,
          ],
          startPoint: .top,
          endPoint: .bottom
        )
        Ellipse()
          .fill(primaryColor.opacity(glowOpacity))
          .frame(width: 560, height: 128)
          .offset(x: leadingGlowOffset, y: -44)
        Ellipse()
          .fill(secondaryColor.opacity(glowOpacity * 0.64))
          .frame(width: 420, height: 112)
          .offset(x: 310, y: 28)
      }
      .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
      .clipped()
      .ignoresSafeArea(.container, edges: .top)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }

  private var shouldRender: Bool {
    !reduceTransparency && !HarnessMonitorUITestEnvironment.disablesVisualOptions
  }

  private var contrastMultiplier: Double {
    colorSchemeContrast == .increased ? 1.18 : 1.0
  }

  private var topOpacity: Double {
    0.34 * model.intensity * contrastMultiplier
  }

  private var midOpacity: Double {
    0.17 * model.intensity * contrastMultiplier
  }

  private var bottomOpacity: Double {
    0.08 * model.intensity * contrastMultiplier
  }

  private var glowOpacity: Double {
    0.22 * model.intensity * contrastMultiplier
  }

  private var leadingGlowOffset: CGFloat {
    switch model.tone {
    case .dashboardTaskBoard:
      92
    case .dashboardPolicyCanvas:
      180
    case .session:
      220
    }
  }

  private var primaryColor: Color {
    switch model.tone {
    case .dashboardTaskBoard:
      return HarnessMonitorTheme.accent
    case .dashboardPolicyCanvas:
      return HarnessMonitorTheme.warmAccent
    case .session(let status, let isStale):
      if isStale {
        return HarnessMonitorTheme.ink
      }
      switch status {
      case .awaitingLeader:
        return HarnessMonitorTheme.accent
      case .active:
        return HarnessMonitorTheme.success
      case .paused, .leaderlessDegraded:
        return HarnessMonitorTheme.caution
      case .ended:
        return HarnessMonitorTheme.ink
      }
    }
  }

  private var secondaryColor: Color {
    switch model.tone {
    case .dashboardTaskBoard:
      return HarnessMonitorTheme.success
    case .dashboardPolicyCanvas:
      return HarnessMonitorTheme.accent
    case .session(let status, let isStale):
      if isStale {
        return HarnessMonitorTheme.caution
      }
      switch status {
      case .active:
        return HarnessMonitorTheme.accent
      case .awaitingLeader:
        return HarnessMonitorTheme.warmAccent
      case .paused, .leaderlessDegraded:
        return HarnessMonitorTheme.caution
      case .ended:
        return HarnessMonitorTheme.ink
      }
    }
  }
}
