import AppKit
import SwiftData
import XCTest
@testable import HarnessMonitor
@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable
@MainActor
extension HarnessMonitorInitialWindowPlanTests {
  func testReplayGroupingsMarksPersistedDashboardGroup() {
    let restorePlan = HarnessMonitorStore.LaunchWindowRestorePlan(
      sessionIDs: ["sess-a", "sess-b"],
      tabGroupings: [
        .init(
          ordinal: 0,
          sessionIDs: ["sess-a", "sess-b"],
          foregroundSessionID: "sess-b"
        )
      ]
    )

    let groupings = HarnessMonitorInitialWindowRouter.replayGroupings(
      in: restorePlan,
      shouldRestoreDashboard: true,
      dashboardTabRestoreState: .init(
        sessionIDs: ["sess-a", "sess-b"],
        wasForegroundTab: false
      )
    )

    XCTAssertEqual(
      groupings,
      [
        .init(
          ordinal: 0,
          sessionIDs: ["sess-a", "sess-b"],
          foregroundSessionID: "sess-b",
          includesDashboard: true
        )
      ]
    )
  }

  func testReplayGroupingsMatchesDashboardGroupIgnoringSessionOrder() {
    let restorePlan = HarnessMonitorStore.LaunchWindowRestorePlan(
      sessionIDs: ["sess-a", "sess-b"],
      tabGroupings: [
        .init(
          ordinal: 0,
          sessionIDs: ["sess-a", "sess-b"],
          foregroundSessionID: "sess-b"
        )
      ]
    )

    let groupings = HarnessMonitorInitialWindowRouter.replayGroupings(
      in: restorePlan,
      shouldRestoreDashboard: true,
      dashboardTabRestoreState: .init(
        sessionIDs: ["sess-b", "sess-a"],
        wasForegroundTab: false
      )
    )

    XCTAssertEqual(
      groupings,
      [
        .init(
          ordinal: 0,
          sessionIDs: ["sess-b", "sess-a"],
          foregroundSessionID: "sess-b",
          includesDashboard: true
        )
      ]
    )
  }

  func testReplayGroupingsSynthesizesDashboardGroupForSingleSurvivingSession() {
    let restorePlan = HarnessMonitorStore.LaunchWindowRestorePlan(
      sessionIDs: ["sess-a"],
      tabGroupings: []
    )

    let groupings = HarnessMonitorInitialWindowRouter.replayGroupings(
      in: restorePlan,
      shouldRestoreDashboard: true,
      dashboardTabRestoreState: .init(
        sessionIDs: ["sess-a", "sess-b"],
        wasForegroundTab: true
      )
    )

    XCTAssertEqual(
      groupings,
      [
        .init(
          ordinal: 0,
          sessionIDs: ["sess-a"],
          includesDashboard: true,
          dashboardWasForeground: true
        )
      ]
    )
  }

  func testReplayGroupingsSynthesizesForegroundSessionForSingleSurvivor() {
    let restorePlan = HarnessMonitorStore.LaunchWindowRestorePlan(
      sessionIDs: ["sess-a"],
      tabGroupings: []
    )

    let groupings = HarnessMonitorInitialWindowRouter.replayGroupings(
      in: restorePlan,
      shouldRestoreDashboard: true,
      dashboardTabRestoreState: .init(
        sessionIDs: ["sess-a", "sess-b"],
        wasForegroundTab: false
      )
    )

    XCTAssertEqual(
      groupings,
      [
        .init(
          ordinal: 0,
          sessionIDs: ["sess-a"],
          foregroundSessionID: "sess-a",
          includesDashboard: true
        )
      ]
    )
  }

  func testEffectiveReplayRestorePlanAddsDashboardStateSessionsWhenRestorePlanMissesThem() {
    let effectivePlan = HarnessMonitorInitialWindowRouter.effectiveReplayRestorePlan(
      in: .init(sessionIDs: []),
      dashboardTabRestoreState: .init(
        sessionIDs: ["sess-bart"],
        wasForegroundTab: false
      ),
      liveBoundSessionIDs: []
    )

    XCTAssertEqual(effectivePlan.sessionIDs, ["sess-bart"])
    XCTAssertTrue(effectivePlan.tabGroupings.isEmpty)
  }

  func testPersistedDashboardTabRestoreReplaysMixedGroupEndToEnd() async throws {
    let suiteName = "io.harnessmonitor.tests.MixedDashboardRestore"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    let tracker = DashboardWindowLifecycleTracker(userDefaults: defaults)
    let registry = SessionWindowAppKitRegistry()

    let liveDashboard = makeRestoredWindow()
    let liveSessionA = makeRestoredWindow()
    let liveSessionB = makeRestoredWindow()
    let restoredDashboard = makeRestoredWindow()
    let restoredSessionA = makeRestoredWindow()
    let restoredSessionB = makeRestoredWindow()
    defer {
      cleanUpWindows([
        liveDashboard, liveSessionA, liveSessionB,
        restoredDashboard, restoredSessionA, restoredSessionB,
      ])
      registry.unbind(window: restoredSessionA)
      registry.unbind(window: restoredSessionB)
      defaults.removePersistentDomain(forName: suiteName)
    }

    tracker.markOpen()
    prepareSharedTabbingIdentity(liveDashboard)
    prepareSharedTabbingIdentity(liveSessionA)
    prepareSharedTabbingIdentity(liveSessionB)
    show([liveDashboard, liveSessionA, liveSessionB])
    liveDashboard.addTabbedWindow(liveSessionA, ordered: .above)
    liveDashboard.addTabbedWindow(liveSessionB, ordered: .above)
    liveDashboard.tabGroup?.selectedWindow = liveDashboard

    let liveBindings = [
      (window: liveSessionA, sessionID: "sess-a"),
      (window: liveSessionB, sessionID: "sess-b"),
    ]
    tracker.flushOpenAtQuit(
      dashboardWindow: liveDashboard,
      sessionBindings: liveBindings
    )

    let groupedSessionIDs: [String] = liveDashboard.tabGroup?.windows.compactMap { window -> String? in
      switch window {
      case liveSessionA:
        "sess-a"
      case liveSessionB:
        "sess-b"
      default:
        nil
      }
    } ?? []
    let restorePlan = HarnessMonitorStore.LaunchWindowRestorePlan(
      sessionIDs: groupedSessionIDs,
      tabGroupings: [
        .init(
          ordinal: 0,
          sessionIDs: groupedSessionIDs
        )
      ]
    )
    let replayGroupings = HarnessMonitorInitialWindowRouter.replayGroupings(
      in: restorePlan,
      shouldRestoreDashboard: true,
      dashboardTabRestoreState: DashboardWindowLifecycleTracker.tabRestoreStateAtQuit(
        userDefaults: defaults
      )
    )

    XCTAssertEqual(
      replayGroupings,
      [
        .init(
          ordinal: 0,
          sessionIDs: groupedSessionIDs,
          includesDashboard: true,
          dashboardWasForeground: true
        )
      ]
    )

    try await replayRestoredDashboardAndAssert(
      MixedReplayContext(
        replayGroupings: replayGroupings,
        registry: registry,
        restoredDashboard: restoredDashboard,
        restoredSessionA: restoredSessionA,
        restoredSessionB: restoredSessionB,
        expectedGroupedSessionIDs: groupedSessionIDs
      )
    )
  }

  private struct MixedReplayContext {
    let replayGroupings: [HarnessMonitorStore.SessionTabGroupSnapshot]
    let registry: SessionWindowAppKitRegistry
    let restoredDashboard: NSWindow
    let restoredSessionA: NSWindow
    let restoredSessionB: NSWindow
    let expectedGroupedSessionIDs: [String]
  }

  private func replayRestoredDashboardAndAssert(_ ctx: MixedReplayContext) async throws {
    ctx.registry.bind(window: ctx.restoredSessionA, sessionID: "sess-a")
    ctx.registry.bind(window: ctx.restoredSessionB, sessionID: "sess-b")
    prepareSharedTabbingIdentity(ctx.restoredDashboard)
    prepareSharedTabbingIdentity(ctx.restoredSessionA)
    prepareSharedTabbingIdentity(ctx.restoredSessionB)
    show([ctx.restoredDashboard, ctx.restoredSessionA, ctx.restoredSessionB])
    let replayOutcome = await SessionWindowTabGroupReplayer.replay(
      ctx.replayGroupings,
      registry: ctx.registry,
      dashboardWindowProvider: { ctx.restoredDashboard },
      timeout: .milliseconds(400),
      pollInterval: .milliseconds(20)
    )
    let restoredGroup = try XCTUnwrap(ctx.restoredDashboard.tabGroup)
    let restoredSessionIDs: [String] = restoredGroup.windows.compactMap { window -> String? in
      switch window {
      case ctx.restoredSessionA: "sess-a"
      case ctx.restoredSessionB: "sess-b"
      default: nil
      }
    }
    XCTAssertEqual(replayOutcome.resolvedGroupCount, 1)
    XCTAssertEqual(replayOutcome.foregroundResolvedCount, 1)
    XCTAssertTrue(restoredGroup === ctx.restoredSessionA.tabGroup)
    XCTAssertTrue(restoredGroup === ctx.restoredSessionB.tabGroup)
    XCTAssertEqual(restoredGroup.windows.first, ctx.restoredDashboard)
    XCTAssertEqual(restoredGroup.selectedWindow, ctx.restoredDashboard)
    XCTAssertEqual(restoredSessionIDs, ctx.expectedGroupedSessionIDs)
  }

  func testRouteRecoversMixedReplayWhenSessionBecomesTabReadyAfterInitialPass() async throws {
    let registry = SessionWindowAppKitRegistry.shared
    registry.resetForTesting()
    DashboardWindowAppKitRegistry.shared.resetForTesting()
    let defaults = UserDefaults.standard
    let sessionID = PreviewFixtures.summary.sessionId
    defaults.set(true, forKey: DashboardWindowLifecycleTracker.openAtQuitKey)
    defaults.set([sessionID], forKey: DashboardWindowLifecycleTracker.tabbedSessionIDsAtQuitKey)
    defaults.set(false, forKey: DashboardWindowLifecycleTracker.wasForegroundTabAtQuitKey)

    let container = try HarnessMonitorModelContainer.preview()
    let cacheService = SessionCacheService(modelContainer: container)
    let store = makeStore(modelContainer: container, cacheService: cacheService)
    XCTAssertTrue(store.sessionIndex.applySessionSummary(PreviewFixtures.summary))
    _ = await cacheService.replaceSessionWindowsOpenAtQuit(
      snapshot: HarnessMonitorStore.SessionWindowQuitSnapshot(sessionIDs: [sessionID])
    )

    var dashboardWindow: NSWindow?
    var sessionWindow: NSWindow?
    defer {
      if let sessionWindow {
        registry.unbind(window: sessionWindow)
      }
      if let dashboardWindow {
        DashboardWindowAppKitRegistry.shared.unbind(window: dashboardWindow)
      }
      cleanUpWindows([dashboardWindow, sessionWindow].compactMap { $0 })
      registry.resetForTesting()
      DashboardWindowAppKitRegistry.shared.resetForTesting()
      defaults.removeObject(forKey: DashboardWindowLifecycleTracker.openAtQuitKey)
      defaults.removeObject(forKey: DashboardWindowLifecycleTracker.tabbedSessionIDsAtQuitKey)
      defaults.removeObject(forKey: DashboardWindowLifecycleTracker.wasForegroundTabAtQuitKey)
    }

    let router = HarnessMonitorInitialWindowRouter(
      store: store,
      launchBehavior: .restoreSessionWindows,
      tabbingPreference: .always,
      openWelcomeWindow: { _ in
        let window = self.makeRestoredWindow()
        dashboardWindow = window
        DashboardWindowAppKitRegistry.shared.bind(window: window)
        self.prepareSharedTabbingIdentity(window)
        self.show([window])
      },
      openSessionWindow: { restoredSessionID, _ in
        let window = self.makeRestoredWindow()
        sessionWindow = window
        registry.bind(window: window, sessionID: restoredSessionID)
        self.show([window])
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(1700))
          self.prepareSharedTabbingIdentity(window)
        }
      }
    )

    await router.route()
    try? await Task.sleep(for: .milliseconds(700))
    await HarnessMonitorInitialWindowRouter.waitForReplayRecoveryForTesting()

    let resolvedDashboardWindow = try XCTUnwrap(dashboardWindow)
    let resolvedSessionWindow = try XCTUnwrap(sessionWindow)
    let resolvedTabGroup = try XCTUnwrap(resolvedDashboardWindow.tabGroup)

    XCTAssertTrue(resolvedSessionWindow.tabGroup === resolvedTabGroup)
    XCTAssertEqual(resolvedTabGroup.windows, [resolvedDashboardWindow, resolvedSessionWindow])
    XCTAssertEqual(resolvedTabGroup.selectedWindow, resolvedSessionWindow)
  }

}
