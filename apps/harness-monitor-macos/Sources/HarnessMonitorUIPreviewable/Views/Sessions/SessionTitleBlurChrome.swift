import HarnessMonitorKit
import SwiftUI

struct SessionTitleBlurChromeConfiguration: Equatable {
  static let accessibilityIdentifier = "harness.session.title-blur-chrome"
  static let height: CGFloat = 160
  // Approximate x-position of the title's first letter in the toolbar:
  // sidebar (~220) + back/forward chevrons (~92) + leading padding.
  static let titleLeadingPadding: CGFloat = 320
  // Vertical center of the bright spot, measured from the top of the chrome
  // band (which starts at the window top via .ignoresSafeArea(.top)). The
  // titlebar/toolbar takes ~28-52pt; placing the center at 56pt keeps it
  // just below the title baseline so the glow blooms downward into content.
  static let titleVerticalOffset: CGFloat = 56
  static let blurWidth: CGFloat = 280
  static let blurHeight: CGFloat = 96
  static let blurRadius: CGFloat = 56
  static let tintOpacity = 0.30
  static let reducedTransparencyOpacity = 0.82

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
    case .awaitingLeader:
      return .attached
    case .active:
      return .completed
    case .paused, .leaderlessDegraded:
      return .degraded
    case .ended:
      return .idle
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

  public var body: some View {
    SessionTitleBlurChromeShape(
      configuration: configuration,
      hasIncreasedContrast: colorSchemeContrast == .increased
    )
    .equatable()
  }
}

private struct SessionTitleBlurChromeShape: View, Equatable {
  let configuration: SessionTitleBlurChromeConfiguration
  let hasIncreasedContrast: Bool

  private var tint: Color {
    Color(configuration.assetName, bundle: HarnessMonitorUIAssets.bundle)
  }

  private var opacity: Double {
    let baseOpacity =
      configuration.reduceTransparency
      ? SessionTitleBlurChromeConfiguration.reducedTransparencyOpacity * 0.35
      : SessionTitleBlurChromeConfiguration.tintOpacity
    return hasIncreasedContrast
      ? baseOpacity * 1.45
      : baseOpacity
  }

  var body: some View {
    titleTint
      .frame(height: SessionTitleBlurChromeConfiguration.height)
      .frame(maxWidth: .infinity, alignment: .top)
      .ignoresSafeArea(.container, edges: .top)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .accessibilityIdentifier(SessionTitleBlurChromeConfiguration.accessibilityIdentifier)
      .transaction { transaction in
        // The blurred opacity overlay spans the window chrome; keep it out
        // of parent animation transactions to avoid invalidating the shell.
        transaction.animation = nil
      }
  }

  private var titleTint: some View {
    let centerX = SessionTitleBlurChromeConfiguration.titleLeadingPadding
    let centerY = SessionTitleBlurChromeConfiguration.titleVerticalOffset
    let blurWidth = SessionTitleBlurChromeConfiguration.blurWidth
    let blurHeight = SessionTitleBlurChromeConfiguration.blurHeight
    return Capsule()
      .fill(tint.opacity(opacity))
      .frame(width: blurWidth, height: blurHeight)
      .blur(radius: SessionTitleBlurChromeConfiguration.blurRadius)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .offset(
        x: centerX - blurWidth / 2,
        y: centerY - blurHeight / 2
      )
  }
}

private struct SessionTitleBlurChromeModifier: ViewModifier {
  let status: SessionStatus
  let isStale: Bool

  @AppStorage(HarnessMonitorSessionTitleBlurDefaults.enabledKey)
  private var isEnabled: Bool = HarnessMonitorSessionTitleBlurDefaults.enabledDefault

  private var shouldShowTitleBlur: Bool {
    isEnabled && !HarnessMonitorUITestEnvironment.disablesVisualOptions
  }

  func body(content: Content) -> some View {
    if shouldShowTitleBlur {
      content.overlay(alignment: .top) {
        SessionTitleBlurChrome(status: status, isStale: isStale)
      }
    } else {
      content
    }
  }
}

extension View {
  public func sessionTitleBlurChrome(status: SessionStatus, isStale: Bool) -> some View {
    modifier(SessionTitleBlurChromeModifier(status: status, isStale: isStale))
  }
}
