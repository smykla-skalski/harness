import HarnessMonitorKit
import SwiftUI

struct SessionTitleBlurChromeConfiguration: Equatable {
  static let accessibilityIdentifier = "harness.session.title-blur-chrome"
  static let height: CGFloat = 96
  static let gradientRadius: CGFloat = 360
  static let titleLeadingPadding: CGFloat = 78
  static let tintOpacity = 0.18
  static let reducedTransparencyOpacity = 0.82
  static let animationDuration = 0.18

  enum Tone: String, Equatable {
    case idle
    case attached
    case degraded
    case completed
  }

  let tone: Tone
  let assetName: String
  let reduceTransparency: Bool

  init(status: SessionStatus, isStale: Bool, reduceTransparency: Bool) {
    tone = Self.tone(status: status, isStale: isStale)
    assetName = Self.assetName(for: tone)
    self.reduceTransparency = reduceTransparency
  }

  private static func tone(status: SessionStatus, isStale: Bool) -> Tone {
    guard !isStale else { return .idle }
    switch status {
    case .awaitingLeader, .paused:
      return .idle
    case .active:
      return .attached
    case .leaderlessDegraded:
      return .degraded
    case .ended:
      return .completed
    }
  }

  private static func assetName(for tone: Tone) -> String {
    switch tone {
    case .idle:
      "HarnessMonitorInk"
    case .attached:
      "HarnessMonitorAccent"
    case .degraded:
      "HarnessMonitorCaution"
    case .completed:
      "HarnessMonitorSuccess"
    }
  }
}

public struct SessionTitleBlurChrome: View {
  let status: SessionStatus
  let isStale: Bool

  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  public init(status: SessionStatus, isStale: Bool) {
    self.status = status
    self.isStale = isStale
  }

  private var configuration: SessionTitleBlurChromeConfiguration {
    SessionTitleBlurChromeConfiguration(
      status: status,
      isStale: isStale,
      reduceTransparency: reduceTransparency
    )
  }

  private var tint: Color {
    Color(configuration.assetName, bundle: HarnessMonitorUIAssets.bundle)
  }

  private var opacity: Double {
    colorSchemeContrast == .increased
      ? SessionTitleBlurChromeConfiguration.tintOpacity * 1.45
      : SessionTitleBlurChromeConfiguration.tintOpacity
  }

  public var body: some View {
    ZStack(alignment: .topLeading) {
      Rectangle()
        .fill(backgroundStyle)
      titleTint
    }
    .frame(height: SessionTitleBlurChromeConfiguration.height)
    .frame(maxWidth: .infinity, alignment: .top)
    .ignoresSafeArea(.container, edges: .top)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
    .accessibilityIdentifier(SessionTitleBlurChromeConfiguration.accessibilityIdentifier)
    .animation(
      .easeInOut(duration: SessionTitleBlurChromeConfiguration.animationDuration),
      value: status
    )
    .animation(
      .easeInOut(duration: SessionTitleBlurChromeConfiguration.animationDuration),
      value: isStale
    )
  }

  private var backgroundStyle: AnyShapeStyle {
    if configuration.reduceTransparency {
      AnyShapeStyle(tint.opacity(SessionTitleBlurChromeConfiguration.reducedTransparencyOpacity))
    } else {
      AnyShapeStyle(.bar)
    }
  }

  private var titleTint: some View {
    let radius = SessionTitleBlurChromeConfiguration.gradientRadius
    return Circle()
      .fill(
        RadialGradient(
          colors: [
            tint.opacity(opacity),
            tint.opacity(opacity * 0.55),
            tint.opacity(0),
          ],
          center: .center,
          startRadius: 0,
          endRadius: radius
        )
      )
      .frame(width: radius * 2, height: radius * 2)
      .offset(
        x: SessionTitleBlurChromeConfiguration.titleLeadingPadding - radius,
        y: -radius + SessionTitleBlurChromeConfiguration.height * 0.35
      )
  }
}

extension View {
  public func sessionTitleBlurChrome(status: SessionStatus, isStale: Bool) -> some View {
    overlay(alignment: .top) {
      SessionTitleBlurChrome(status: status, isStale: isStale)
    }
  }
}
