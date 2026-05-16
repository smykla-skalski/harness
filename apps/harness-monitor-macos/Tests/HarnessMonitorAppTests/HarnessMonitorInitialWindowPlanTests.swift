import AppKit
import SwiftData
import XCTest

@testable import HarnessMonitor
@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
final class HarnessMonitorInitialWindowPlanTests: XCTestCase {
  private var previousAllowsAutomaticWindowTabbing = NSWindow.allowsAutomaticWindowTabbing

  override func setUp() async throws {
    try await super.setUp()
    previousAllowsAutomaticWindowTabbing = NSWindow.allowsAutomaticWindowTabbing
    NSWindow.allowsAutomaticWindowTabbing = false
    HarnessMonitorInitialWindowRouter.resetReplayRecoveryForTesting()
  }

  override func tearDown() async throws {
    await HarnessMonitorInitialWindowRouter.waitForReplayRecoveryForTesting()
    HarnessMonitorInitialWindowRouter.resetReplayRecoveryForTesting()
    NSWindow.allowsAutomaticWindowTabbing = previousAllowsAutomaticWindowTabbing
    try await super.tearDown()
  }

  func testVisibleSessionWindowsSuppressRestoreLaunchActions() {
    let plan = HarnessMonitorInitialWindowPlan.resolve(
      launchBehavior: .restoreSessionWindows,
      hasVisibleSessionWindows: true,
      restorePlan: .init(sessionIDs: ["sess-a"], usedBridgeFallback: true)
    )

    XCTAssertEqual(plan.destination, .none)
    XCTAssertFalse(plan.shouldMarkBridgeFallbackComplete)
  }

  func testAlwaysOpenRecentOpensWelcomeWindow() {
    let plan = HarnessMonitorInitialWindowPlan.resolve(
      launchBehavior: .alwaysOpenRecent,
      hasVisibleSessionWindows: false
    )

    XCTAssertEqual(plan.destination, .welcome)
    XCTAssertFalse(plan.shouldMarkBridgeFallbackComplete)
  }

  func testAlwaysOpenRecentIgnoresVisibleSessionWindows() {
    let plan = HarnessMonitorInitialWindowPlan.resolve(
      launchBehavior: .alwaysOpenRecent,
      hasVisibleSessionWindows: true,
      restorePlan: .init(sessionIDs: ["sess-a"])
    )

    XCTAssertEqual(plan.destination, .welcome)
    XCTAssertFalse(plan.shouldMarkBridgeFallbackComplete)
  }

  func testRestoreSessionWindowsOpensTrackedSessions() {
    let plan = HarnessMonitorInitialWindowPlan.resolve(
      launchBehavior: .restoreSessionWindows,
      hasVisibleSessionWindows: false,
      restorePlan: .init(sessionIDs: ["sess-a", "sess-b"], usedBridgeFallback: true)
    )

    XCTAssertEqual(plan.destination, .sessions(["sess-a", "sess-b"]))
    XCTAssertTrue(plan.shouldMarkBridgeFallbackComplete)
  }

  func testRestoreSessionWindowsFallsBackToWelcomeWhenNothingRestored() {
    let plan = HarnessMonitorInitialWindowPlan.resolve(
      launchBehavior: .restoreSessionWindows,
      hasVisibleSessionWindows: false,
      restorePlan: .init(sessionIDs: [], usedBridgeFallback: true)
    )

    XCTAssertEqual(plan.destination, .welcome)
    XCTAssertTrue(plan.shouldMarkBridgeFallbackComplete)
  }

  func testLaunchBehaviorCopyDocumentsSessionWindowRelaunchEffects() throws {
    let copy = HarnessMonitorLaunchBehavior.closingBehaviorDescription
    let settingsSource = try uiPreviewableSourceFile(named: "Views/Settings/SettingsGeneralSection.swift")

    XCTAssertTrue(copy.contains("Command-W"))
    XCTAssertTrue(copy.contains("red close button"))
    XCTAssertTrue(copy.contains("left open at quit"))
    XCTAssertTrue(copy.contains("minimized session windows restore visible"))
    XCTAssertTrue(settingsSource.contains("HarnessMonitorLaunchBehavior.closingBehaviorDescription"))
  }

  @MainActor
  func testRestoreSessionWindowsOpensDashboardBeforeRestoredSessions() async throws {
    let registry = SessionWindowAppKitRegistry.shared
    registry.resetForTesting()
    let defaults = UserDefaults.standard
    defaults.set(true, forKey: DashboardWindowLifecycleTracker.openAtQuitKey)

    let container = try HarnessMonitorModelContainer.preview()
    let cacheService = SessionCacheService(modelContainer: container)
    let store = makeStore(modelContainer: container, cacheService: cacheService)
    let sessionIDs = try seedRestoreSessions(into: store)
    _ = await cacheService.replaceSessionWindowsOpenAtQuit(
      snapshot: HarnessMonitorStore.SessionWindowQuitSnapshot(
        sessionIDs: Set(sessionIDs),
        groupings: [
          HarnessMonitorStore.SessionTabGroupSnapshot(
            ordinal: 0,
            sessionIDs: sessionIDs,
            foregroundSessionID: sessionIDs[1]
          )
        ]
      )
    )

    var openOrder: [String] = []
    var dashboardMergeFlags: [Bool] = []
    var sessionMergeFlags: [Bool] = []
    var windows: [NSWindow] = []
    defer {
      for window in windows.reversed() {
        registry.unbind(window: window)
        window.orderOut(nil)
      }
      registry.resetForTesting()
      defaults.removeObject(forKey: DashboardWindowLifecycleTracker.openAtQuitKey)
      defaults.removeObject(forKey: DashboardWindowLifecycleTracker.tabbedSessionIDsAtQuitKey)
      defaults.removeObject(forKey: DashboardWindowLifecycleTracker.wasForegroundTabAtQuitKey)
    }

    let router = HarnessMonitorInitialWindowRouter(
      store: store,
      launchBehavior: .restoreSessionWindows,
      tabbingPreference: .never,
      openWelcomeWindow: { mergeIfNeeded in
        dashboardMergeFlags.append(mergeIfNeeded)
        openOrder.append("dashboard")
      },
      openSessionWindow: { sessionID, mergeIfNeeded in
        sessionMergeFlags.append(mergeIfNeeded)
        openOrder.append(sessionID)
        let window = self.makeRestoredWindow()
        registry.bind(window: window, sessionID: sessionID)
        windows.append(window)
      }
    )

    await router.route()

    XCTAssertEqual(openOrder, ["dashboard"] + sessionIDs)
    XCTAssertEqual(dashboardMergeFlags, [false])
    XCTAssertEqual(sessionMergeFlags, Array(repeating: false, count: sessionIDs.count))
  }

  @MainActor
  func testAlwaysOpenRecentKeepsNormalDashboardOpenBehavior() async throws {
    let container = try HarnessMonitorModelContainer.preview()
    let cacheService = SessionCacheService(modelContainer: container)
    let store = makeStore(modelContainer: container, cacheService: cacheService)
    var dashboardMergeFlags: [Bool] = []

    let router = HarnessMonitorInitialWindowRouter(
      store: store,
      launchBehavior: .alwaysOpenRecent,
      tabbingPreference: .always,
      openWelcomeWindow: { mergeIfNeeded in
        dashboardMergeFlags.append(mergeIfNeeded)
      },
      openSessionWindow: { _, _ in
        XCTFail("Always-open-recent should not restore session windows")
      }
    )

    await router.route()

    XCTAssertEqual(dashboardMergeFlags, [true])
  }

  @MainActor
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

  @MainActor
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

  @MainActor
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

  @MainActor
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

  @MainActor
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

  @MainActor
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

    registry.bind(window: restoredSessionA, sessionID: "sess-a")
    registry.bind(window: restoredSessionB, sessionID: "sess-b")
    prepareSharedTabbingIdentity(restoredDashboard)
    prepareSharedTabbingIdentity(restoredSessionA)
    prepareSharedTabbingIdentity(restoredSessionB)
    show([restoredDashboard, restoredSessionA, restoredSessionB])

    let replayOutcome = await SessionWindowTabGroupReplayer.replay(
      replayGroupings,
      registry: registry,
      dashboardWindowProvider: { restoredDashboard },
      timeout: .milliseconds(400),
      pollInterval: .milliseconds(20)
    )

    let restoredGroup = try XCTUnwrap(restoredDashboard.tabGroup)
    let restoredSessionIDs: [String] = restoredGroup.windows.compactMap { window -> String? in
      switch window {
      case restoredSessionA:
        "sess-a"
      case restoredSessionB:
        "sess-b"
      default:
        nil
      }
    }
    XCTAssertEqual(replayOutcome.resolvedGroupCount, 1)
    XCTAssertEqual(replayOutcome.foregroundResolvedCount, 1)
    XCTAssertTrue(restoredGroup === restoredSessionA.tabGroup)
    XCTAssertTrue(restoredGroup === restoredSessionB.tabGroup)
    XCTAssertEqual(restoredGroup.windows.first, restoredDashboard)
    XCTAssertEqual(restoredGroup.selectedWindow, restoredDashboard)
    XCTAssertEqual(restoredSessionIDs, groupedSessionIDs)
  }

  @MainActor
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

  private func uiPreviewableSourceFile(named relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }

  @MainActor
  private func makeStore(
    modelContainer: ModelContainer,
    cacheService: SessionCacheService
  ) -> HarnessMonitorStore {
    HarnessMonitorStore(
      daemonController: PreviewDaemonController(mode: .empty),
      voiceCapture: PreviewVoiceCaptureService(),
      daemonOwnership: .managed,
      modelContainer: modelContainer,
      cacheService: cacheService
    )
  }

  @MainActor
  private func seedRestoreSessions(
    into store: HarnessMonitorStore
  ) throws -> [String] {
    let tertiarySummary = try XCTUnwrap(
      PreviewFixtures.overflowSessions.first {
        $0.sessionId != PreviewFixtures.summary.sessionId
          && $0.sessionId != PreviewFixtures.signalRegressionSecondarySummary.sessionId
      }
    )
    let summaries = [
      PreviewFixtures.summary,
      PreviewFixtures.signalRegressionSecondarySummary,
      tertiarySummary,
    ]
    for summary in summaries {
      let didApply = store.sessionIndex.applySessionSummary(summary)
      XCTAssertTrue(didApply)
    }
    return summaries.map(\.sessionId)
  }

  @MainActor
  private func makeRestoredWindow() -> NSWindow {
    NSWindow(
      contentRect: .init(x: 0, y: 0, width: 480, height: 320),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
  }

  @MainActor
  private func prepareSharedTabbingIdentity(_ window: NSWindow) {
    SessionWindowTabbingSupport.prepareWindowForTabbing(window, preference: .always)
  }

  @MainActor
  private func show(_ windows: [NSWindow]) {
    for window in windows.dropLast() {
      window.orderFront(nil)
    }
    windows.last?.makeKeyAndOrderFront(nil)
  }

  @MainActor
  private func cleanUpWindows(_ windows: [NSWindow]) {
    for window in windows.reversed() {
      window.orderOut(nil)
    }
  }
}
