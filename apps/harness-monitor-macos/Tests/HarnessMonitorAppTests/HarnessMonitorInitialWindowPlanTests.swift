import AppKit
import SwiftData
import XCTest

@testable import HarnessMonitor
@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

final class HarnessMonitorInitialWindowPlanTests: XCTestCase {
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
    var windows: [NSWindow] = []
    defer {
      for window in windows.reversed() {
        registry.unbind(window: window)
        window.orderOut(nil)
      }
      registry.resetForTesting()
      defaults.removeObject(forKey: DashboardWindowLifecycleTracker.openAtQuitKey)
    }

    let router = HarnessMonitorInitialWindowRouter(
      store: store,
      launchBehavior: .restoreSessionWindows,
      tabbingPreference: .never,
      openWelcomeWindow: {
        openOrder.append("dashboard")
      },
      openSessionWindow: { sessionID in
        openOrder.append(sessionID)
        let window = self.makeRestoredWindow()
        registry.bind(window: window, sessionID: sessionID)
        windows.append(window)
      }
    )

    await router.route()

    XCTAssertEqual(openOrder, ["dashboard"] + sessionIDs)
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
}
