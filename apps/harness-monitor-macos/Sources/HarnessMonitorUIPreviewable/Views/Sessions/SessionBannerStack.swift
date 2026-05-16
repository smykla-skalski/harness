import Combine
import HarnessMonitorKit
import SwiftUI

private struct SessionPendingDecisionBannerPreferenceState: Equatable {
  var showsPendingDecisionBanners: Bool
  var showsPendingDecisionBannersInFocusMode: Bool

  static func read(userDefaults: UserDefaults = .standard) -> Self {
    Self(
      showsPendingDecisionBanners: SessionPendingDecisionBannerSettings.readEnabled(
        userDefaults: userDefaults
      ),
      showsPendingDecisionBannersInFocusMode:
        SessionPendingDecisionBannerSettings
        .readFocusModeEnabled(userDefaults: userDefaults)
    )
  }
}

struct SessionBannerStackModel: Equatable {
  let showsContentChrome: Bool
  let showsLoading: Bool
  let showsPendingDecisionBanner: Bool
  let pendingDecisionCount: Int
  let observedDaemonWireVersion: Int?

  init(
    contentChrome: ContentChromeBannerModel,
    isLoading: Bool,
    hasSnapshot: Bool,
    showsPendingDecisionBanner: Bool,
    pendingDecisionCount: Int,
    observedDaemonWireVersion: Int?
  ) {
    showsContentChrome = contentChrome.isPresented
    showsLoading = isLoading && !hasSnapshot
    self.showsPendingDecisionBanner = showsPendingDecisionBanner
    self.pendingDecisionCount = pendingDecisionCount
    self.observedDaemonWireVersion = observedDaemonWireVersion
  }

  init(
    persistenceError: String?,
    sessionDataAvailability: HarnessMonitorStore.SessionDataAvailability,
    mcpStatus: HarnessMonitorMCPStatusSnapshot,
    hasACPBridgeBanner: Bool,
    isLoading: Bool,
    hasSnapshot: Bool,
    showsPendingDecisionBanner: Bool,
    pendingDecisionCount: Int,
    observedDaemonWireVersion: Int?
  ) {
    self.init(
      contentChrome: ContentChromeBannerModel(
        persistenceError: persistenceError,
        sessionDataAvailability: sessionDataAvailability,
        mcpStatus: mcpStatus,
        hasACPBridgeBanner: hasACPBridgeBanner
      ),
      isLoading: isLoading,
      hasSnapshot: hasSnapshot,
      showsPendingDecisionBanner: showsPendingDecisionBanner,
      pendingDecisionCount: pendingDecisionCount,
      observedDaemonWireVersion: observedDaemonWireVersion
    )
  }

  var showsDaemonWireVersionSkew: Bool {
    guard let observedDaemonWireVersion else { return false }
    return observedDaemonWireVersion < HarnessMonitorStore.minimumDaemonWireVersion
  }

  var isPresented: Bool {
    showsContentChrome
      || showsLoading
      || (showsPendingDecisionBanner && pendingDecisionCount > 0)
      || showsDaemonWireVersionSkew
  }
}

struct SessionBannerStackMetrics: Equatable {
  let itemSpacing: CGFloat
  let horizontalPadding: CGFloat
  let verticalPadding: CGFloat
  let actionVerticalPadding: CGFloat
  let reviewButtonMinHeight: CGFloat

  init(fontScale: CGFloat) {
    let scale = SessionWindowFontScale.metricsScale(for: fontScale)
    itemSpacing = HarnessMonitorTheme.itemSpacing * min(scale, 1.4)
    horizontalPadding = HarnessMonitorTheme.spacingMD * min(scale, 1.35)
    verticalPadding = HarnessMonitorTheme.spacingSM * min(scale, 1.45)
    actionVerticalPadding = HarnessMonitorTheme.spacingXS * min(scale, 1.3)
    reviewButtonMinHeight = scale >= 1.45 ? 44 : 0
  }
}

public struct SessionBannerStack<Content: View>: View {
  let store: HarnessMonitorStore
  let sessionID: String
  let isFocusMode: Bool
  let isLoading: Bool
  let hasSnapshot: Bool
  let pendingDecisionCount: Int
  let selectDecisions: (() -> Void)?
  let content: Content
  @State private var preferenceState = SessionPendingDecisionBannerPreferenceState.read()

  public init(
    store: HarnessMonitorStore,
    sessionID: String,
    isFocusMode: Bool = false,
    isLoading: Bool = false,
    hasSnapshot: Bool = true,
    pendingDecisionCount: Int,
    selectDecisions: (() -> Void)? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.store = store
    self.sessionID = sessionID
    self.isFocusMode = isFocusMode
    self.isLoading = isLoading
    self.hasSnapshot = hasSnapshot
    self.pendingDecisionCount = pendingDecisionCount
    self.selectDecisions = selectDecisions
    self.content = content()
  }

  private var chrome: HarnessMonitorStore.ContentChromeSlice {
    store.contentUI.chrome
  }

  private var chromeBannerModel: ContentChromeBannerModel {
    ContentChromeBannerModel(
      persistenceError: chrome.persistenceError,
      sessionDataAvailability: chrome.sessionDataAvailability,
      mcpStatus: chrome.mcpStatus,
      hasACPBridgeBanner: chrome.acpBridgeBanner != nil
    )
  }

  private var model: SessionBannerStackModel {
    SessionBannerStackModel(
      contentChrome: chromeBannerModel,
      isLoading: isLoading,
      hasSnapshot: hasSnapshot,
      showsPendingDecisionBanner:
        preferenceState.showsPendingDecisionBanners
        && (!isFocusMode || preferenceState.showsPendingDecisionBannersInFocusMode),
      pendingDecisionCount: pendingDecisionCount,
      observedDaemonWireVersion: store.health?.wireVersion
    )
  }

  public var body: some View {
    WindowBannerChrome(
      windowID: HarnessMonitorWindowID.sessionWindow(sessionID),
      isPresented: model.isPresented
    ) {
      content
    } banners: {
      topChrome
    }
    .onReceive(
      NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
        .receive(on: RunLoop.main)
    ) { _ in
      refreshPreferenceState()
    }
  }

  private func refreshPreferenceState(userDefaults: UserDefaults = .standard) {
    let nextPreferenceState = SessionPendingDecisionBannerPreferenceState.read(
      userDefaults: userDefaults
    )
    if preferenceState != nextPreferenceState {
      preferenceState = nextPreferenceState
    }
  }

  @ViewBuilder private var topChrome: some View {
    VStack(spacing: 0) {
      if let observed = model.observedDaemonWireVersion, model.showsDaemonWireVersionSkew {
        DaemonWireVersionSkewBanner(
          observed: observed,
          expected: HarnessMonitorStore.minimumDaemonWireVersion
        )
        chromeDivider(tint: HarnessMonitorTheme.danger)
      }
      ContentChromeBannerStack(
        store: store,
        contentChrome: chrome,
        windowID: HarnessMonitorWindowID.sessionWindow(sessionID)
      )
      if model.showsLoading {
        SessionLoadingBanner()
        chromeDivider(tint: HarnessMonitorTheme.accent)
      }
      if model.showsPendingDecisionBanner && pendingDecisionCount > 0 {
        SessionDecisionAttentionBanner(
          count: pendingDecisionCount,
          selectDecisions: selectDecisions
        )
        chromeDivider(tint: HarnessMonitorTheme.accent)
      }
    }
  }

  private func chromeDivider(tint: Color) -> some View {
    WindowBannerDivider(tint: tint)
  }
}

private struct SessionLoadingBanner: View {
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: SessionBannerStackMetrics {
    SessionBannerStackMetrics(fontScale: fontScale)
  }

  var body: some View {
    HStack(alignment: .center, spacing: metrics.itemSpacing) {
      Image(systemName: "hourglass")
        .scaledFont(.caption)
        .controlSize(.small)
        .accessibilityHidden(true)
      Text("Loading session detail from daemon.")
        .scaledFont(.caption.weight(.medium))
      Spacer(minLength: 0)
    }
    .padding(.horizontal, metrics.horizontalPadding)
    .padding(.vertical, metrics.verticalPadding)
    .dynamicTypeSize(.xSmall ... .accessibility5)
    .foregroundStyle(HarnessMonitorTheme.accent)
    .modifier(ChromeBannerSurfaceModifier(tint: HarnessMonitorTheme.accent))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading session detail from daemon")
  }
}

private struct SessionDecisionAttentionBanner: View {
  let count: Int
  let selectDecisions: (() -> Void)?
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: SessionBannerStackMetrics {
    SessionBannerStackMetrics(fontScale: fontScale)
  }

  private var message: String {
    if count == 1 {
      return "1 pending decision needs attention."
    }
    return "\(count) pending decisions need attention."
  }

  private var bannerVerticalPadding: CGFloat {
    selectDecisions == nil ? metrics.verticalPadding : metrics.actionVerticalPadding
  }

  var body: some View {
    HStack(alignment: .center, spacing: metrics.itemSpacing) {
      Label {
        Text(message)
          .scaledFont(.caption.weight(.medium))
      } icon: {
        Image(systemName: "exclamationmark.bubble")
          .scaledFont(.caption)
      }
      .labelStyle(.titleAndIcon)
      Spacer(minLength: 0)
      if let selectDecisions {
        Button("Review", action: selectDecisions)
          .harnessActionButtonStyle(variant: .bordered, tint: nil)
          .harnessNativeFormControl()
          .frame(minHeight: metrics.reviewButtonMinHeight)
          .accessibilityLabel("Review pending decisions")
      }
    }
    .padding(.horizontal, metrics.horizontalPadding)
    .padding(.vertical, bannerVerticalPadding)
    .dynamicTypeSize(.xSmall ... .accessibility5)
    .foregroundStyle(HarnessMonitorTheme.accent)
    .modifier(ChromeBannerSurfaceModifier(tint: HarnessMonitorTheme.accent))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text(message))
  }
}
