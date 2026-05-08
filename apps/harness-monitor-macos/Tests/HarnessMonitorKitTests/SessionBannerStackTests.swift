import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Session banner stack model")
struct SessionBannerStackTests {
  @Test("Clean live session hides the banner stack")
  func cleanLiveSessionHidesBannerStack() {
    let model = makeModel()

    #expect(!model.isPresented)
  }

  @Test("Loading session without a snapshot shows the banner stack")
  func loadingSessionWithoutSnapshotShowsBannerStack() {
    let model = makeModel(isLoading: true, hasSnapshot: false)

    #expect(model.showsLoading)
    #expect(model.isPresented)
  }

  @Test("Global chrome outages show the session banner stack")
  func globalChromeOutagesShowBannerStack() {
    #expect(makeModel(persistenceError: "Persistence unavailable").isPresented)
    #expect(
      makeModel(sessionDataAvailability: .unavailable(reason: .daemonOffline("offline")))
        .isPresented
    )
    #expect(
      makeModel(
        mcpStatus: HarnessMonitorMCPStatusSnapshot(
          runtimeState: .degraded(socketPath: nil, reason: "socket closed"),
          recoveryStatus: nil
        )
      ).isPresented
    )
    #expect(makeModel(hasACPBridgeBanner: true).isPresented)
  }

  @Test("Pending decisions show the session attention banner")
  func pendingDecisionsShowAttentionBanner() {
    let model = makeModel(pendingDecisionCount: 3)

    #expect(model.pendingDecisionCount == 3)
    #expect(model.isPresented)
  }

  @Test("Banner metrics scale chrome and preserve large hit targets")
  func bannerMetricsScaleChromeAndPreserveLargeHitTargets() {
    let regular = SessionBannerStackMetrics(fontScale: 1)
    let large = SessionBannerStackMetrics(fontScale: 1.8)

    #expect(large.itemSpacing > regular.itemSpacing)
    #expect(large.horizontalPadding > regular.horizontalPadding)
    #expect(large.verticalPadding > regular.verticalPadding)
    #expect(large.reviewButtonMinHeight == 44)
  }

  @Test("Banner metrics clamp extreme font scales")
  func bannerMetricsClampExtremeFontScales() {
    #expect(
      SessionBannerStackMetrics(fontScale: 0.1)
        == SessionBannerStackMetrics(fontScale: 0.85)
    )
    #expect(
      SessionBannerStackMetrics(fontScale: 9.0)
        == SessionBannerStackMetrics(fontScale: 1.8)
    )
  }

  private func makeModel(
    persistenceError: String? = nil,
    sessionDataAvailability: HarnessMonitorStore.SessionDataAvailability = .live,
    mcpStatus: HarnessMonitorMCPStatusSnapshot = HarnessMonitorMCPStatusSnapshot(
      runtimeState: .disabled,
      recoveryStatus: nil
    ),
    hasACPBridgeBanner: Bool = false,
    isLoading: Bool = false,
    hasSnapshot: Bool = true,
    pendingDecisionCount: Int = 0
  ) -> SessionBannerStackModel {
    SessionBannerStackModel(
      persistenceError: persistenceError,
      sessionDataAvailability: sessionDataAvailability,
      mcpStatus: mcpStatus,
      hasACPBridgeBanner: hasACPBridgeBanner,
      isLoading: isLoading,
      hasSnapshot: hasSnapshot,
      pendingDecisionCount: pendingDecisionCount
    )
  }
}
