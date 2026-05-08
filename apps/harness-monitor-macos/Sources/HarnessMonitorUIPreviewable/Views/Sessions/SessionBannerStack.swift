import HarnessMonitorKit
import SwiftUI

struct SessionBannerStackModel: Equatable {
  let showsPersistenceError: Bool
  let showsStaleData: Bool
  let showsMCPStatus: Bool
  let showsACPBridge: Bool
  let showsLoading: Bool
  let pendingDecisionCount: Int

  init(
    persistenceError: String?,
    sessionDataAvailability: HarnessMonitorStore.SessionDataAvailability,
    mcpStatus: HarnessMonitorMCPStatusSnapshot,
    hasACPBridgeBanner: Bool,
    isLoading: Bool,
    hasSnapshot: Bool,
    pendingDecisionCount: Int
  ) {
    showsPersistenceError = persistenceError != nil
    showsStaleData = sessionDataAvailability != .live
    showsMCPStatus = mcpStatus.shouldShowChromeBanner
    showsACPBridge = hasACPBridgeBanner
    showsLoading = isLoading && !hasSnapshot
    self.pendingDecisionCount = pendingDecisionCount
  }

  var isPresented: Bool {
    showsPersistenceError
      || showsStaleData
      || showsMCPStatus
      || showsACPBridge
      || showsLoading
      || pendingDecisionCount > 0
  }
}

struct SessionBannerStackMetrics: Equatable {
  let itemSpacing: CGFloat
  let horizontalPadding: CGFloat
  let verticalPadding: CGFloat
  let reviewButtonMinHeight: CGFloat

  init(fontScale: CGFloat) {
    let scale = SessionWindowFontScale.metricsScale(for: fontScale)
    itemSpacing = HarnessMonitorTheme.itemSpacing * min(scale, 1.4)
    horizontalPadding = HarnessMonitorTheme.spacingMD * min(scale, 1.35)
    verticalPadding = HarnessMonitorTheme.spacingSM * min(scale, 1.45)
    reviewButtonMinHeight = scale >= 1.45 ? 44 : 0
  }
}

public struct SessionBannerStack<Content: View>: View {
  let store: HarnessMonitorStore
  let sessionID: String
  let isLoading: Bool
  let hasSnapshot: Bool
  let pendingDecisionCount: Int
  let selectDecisions: (() -> Void)?
  let content: Content

  public init(
    store: HarnessMonitorStore,
    sessionID: String,
    isLoading: Bool = false,
    hasSnapshot: Bool = true,
    pendingDecisionCount: Int,
    selectDecisions: (() -> Void)? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.store = store
    self.sessionID = sessionID
    self.isLoading = isLoading
    self.hasSnapshot = hasSnapshot
    self.pendingDecisionCount = pendingDecisionCount
    self.selectDecisions = selectDecisions
    self.content = content()
  }

  private var chrome: HarnessMonitorStore.ContentChromeSlice {
    store.contentUI.chrome
  }

  private var model: SessionBannerStackModel {
    SessionBannerStackModel(
      persistenceError: chrome.persistenceError,
      sessionDataAvailability: chrome.sessionDataAvailability,
      mcpStatus: chrome.mcpStatus,
      hasACPBridgeBanner: chrome.acpBridgeBanner != nil,
      isLoading: isLoading,
      hasSnapshot: hasSnapshot,
      pendingDecisionCount: pendingDecisionCount
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
  }

  @ViewBuilder private var topChrome: some View {
    VStack(spacing: 0) {
      if let persistenceError = chrome.persistenceError {
        PersistenceUnavailableBanner(message: persistenceError)
        chromeDivider(tint: HarnessMonitorTheme.caution)
      }
      if chrome.sessionDataAvailability != .live {
        SessionDataAvailabilityBanner(availability: chrome.sessionDataAvailability)
        chromeDivider(tint: HarnessMonitorTheme.caution)
      }
      if model.showsLoading {
        SessionLoadingBanner()
        chromeDivider(tint: HarnessMonitorTheme.accent)
      }
      if chrome.mcpStatus.shouldShowChromeBanner {
        MCPStatusBanner(status: chrome.mcpStatus)
        chromeDivider(tint: MCPStatusViewSupport.tint(for: chrome.mcpStatus.tone))
      }
      if chrome.acpBridgeBanner != nil {
        ContentAcpBridgeBannerBridge(
          store: store,
          contentChrome: chrome,
          keyWindowObserver: nil,
          windowID: HarnessMonitorWindowID.sessionWindow(sessionID)
        )
        chromeDivider(tint: HarnessMonitorTheme.caution)
      }
      if pendingDecisionCount > 0 {
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
      ProgressView()
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
    let suffix = count == 1 ? "" : "s"
    return "\(count) pending decision\(suffix) need attention."
  }

  var body: some View {
    HStack(alignment: .center, spacing: metrics.itemSpacing) {
      Image(systemName: "exclamationmark.bubble")
        .scaledFont(.caption)
        .accessibilityHidden(true)
      Text(message)
        .scaledFont(.caption.weight(.medium))
      Spacer(minLength: 0)
      if let selectDecisions {
        Button("Review", action: selectDecisions)
          .buttonStyle(.borderless)
          .frame(minHeight: metrics.reviewButtonMinHeight)
          .accessibilityLabel("Review pending decisions")
      }
    }
    .padding(.horizontal, metrics.horizontalPadding)
    .padding(.vertical, metrics.verticalPadding)
    .dynamicTypeSize(.xSmall ... .accessibility5)
    .foregroundStyle(HarnessMonitorTheme.accent)
    .modifier(ChromeBannerSurfaceModifier(tint: HarnessMonitorTheme.accent))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text(message))
  }
}
