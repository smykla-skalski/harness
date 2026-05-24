#if canImport(AppKit)
  import AppKit
  import SwiftUI
  import XCTest

  @testable import HarnessMonitor
  @testable import HarnessMonitorKit
  @testable import HarnessMonitorUIPreviewable

  extension SessionWindowQuitCaptureTests {
    func testAppInactivityPersistenceRefreshesRestoreArtifactsWithoutTermination() async throws {
      let container = try HarnessMonitorModelContainer.preview()
      let cacheService = SessionCacheService(modelContainer: container)
      let store = makeStore(modelContainer: container, cacheService: cacheService)
      let delegate = HarnessMonitorAppDelegate()
      let sessionID = PreviewFixtures.summary.sessionId
      XCTAssertTrue(store.sessionIndex.applySessionSummary(PreviewFixtures.summary))

      let dashboardWindow = makeWindow(origin: .zero)
      let sessionWindow = makeWindow(origin: .init(x: 24, y: 24))
      let dashboardHost = mountHostingContent(
        dashboardWindow,
        rootView: AnyView(
          Color.clear
            .frame(width: 16, height: 16)
            .modifier(DashboardWindowAppKitBinding())
            .modifier(SessionWindowTabbing(role: .dashboard))
            .modifier(DashboardWindowLifecycleModifier())
        )
      )
      let sessionHost = mountHostingContent(
        sessionWindow,
        rootView: AnyView(
          Color.clear
            .frame(width: 16, height: 16)
            .modifier(SessionWindowAppKitBinding(sessionID: sessionID))
            .modifier(SessionWindowTabbing(role: .session, tabTitle: "bart"))
        )
      )
      defer {
        cleanUp(windows: [dashboardWindow, sessionWindow], views: [dashboardHost, sessionHost])
      }

      show([dashboardWindow, sessionWindow])
      drainMainRunLoop()
      dashboardWindow.addTabbedWindow(sessionWindow, ordered: .above)
      dashboardWindow.tabGroup?.selectedWindow = sessionWindow
      drainMainRunLoop()

      await delegate.persistWindowRestoreStateForAppInactivity(
        using: store,
        userDefaults: userDefaults
      )

      let dashboardTabRestoreState = DashboardWindowLifecycleTracker.tabRestoreStateAtQuit(
        userDefaults: userDefaults
      )
      XCTAssertTrue(DashboardWindowLifecycleTracker.wasOpenAtQuit(userDefaults: userDefaults))
      XCTAssertEqual(
        dashboardTabRestoreState,
        .init(sessionIDs: [sessionID], wasForegroundTab: false)
      )

      let restorePlan = await store.launchWindowRestorePlan(userDefaults: userDefaults)
      XCTAssertEqual(restorePlan.sessionIDs, [sessionID])
      XCTAssertTrue(restorePlan.tabGroupings.isEmpty)

      let replayRestorePlan = HarnessMonitorInitialWindowRouter.effectiveReplayRestorePlan(
        in: restorePlan,
        dashboardTabRestoreState: dashboardTabRestoreState,
        liveBoundSessionIDs: []
      )
      XCTAssertEqual(replayRestorePlan.sessionIDs, [sessionID])
      XCTAssertEqual(
        HarnessMonitorInitialWindowRouter.replayGroupings(
          in: replayRestorePlan,
          shouldRestoreDashboard: true,
          dashboardTabRestoreState: dashboardTabRestoreState
        ),
        [
          HarnessMonitorStore.SessionTabGroupSnapshot(
            ordinal: 0,
            sessionIDs: [sessionID],
            foregroundSessionID: sessionID,
            includesDashboard: true
          )
        ]
      )
    }

    func testDirectSnapshotPersistenceLeavesPendingTerminationSnapshotUntouched() async throws {
      let container = try HarnessMonitorModelContainer.preview()
      let cacheService = SessionCacheService(modelContainer: container)
      let store = makeStore(modelContainer: container, cacheService: cacheService)
      let inactivitySessionID = PreviewFixtures.summary.sessionId
      XCTAssertTrue(store.sessionIndex.applySessionSummary(PreviewFixtures.summary))

      let terminationSnapshot = HarnessMonitorStore.SessionWindowQuitSnapshot(
        sessionIDs: ["sess-a", "sess-b"],
        groupings: [
          HarnessMonitorStore.SessionTabGroupSnapshot(
            ordinal: 0,
            sessionIDs: ["sess-a", "sess-b"],
            foregroundSessionID: "sess-b"
          )
        ]
      )
      store.beginSessionWindowTerminationSnapshot(quitSnapshot: terminationSnapshot)

      await store.persistSessionWindowRestoreSnapshot(
        HarnessMonitorStore.SessionWindowQuitSnapshot(sessionIDs: [inactivitySessionID]),
        userDefaults: userDefaults
      )

      XCTAssertEqual(
        store.pendingSessionWindowTerminationSnapshot,
        terminationSnapshot.sessionIDs
      )
      XCTAssertEqual(store.pendingSessionWindowQuitSnapshot, terminationSnapshot)

      let restorePlan = await store.launchWindowRestorePlan(userDefaults: userDefaults)
      XCTAssertEqual(restorePlan.sessionIDs, [inactivitySessionID])
      XCTAssertTrue(restorePlan.tabGroupings.isEmpty)
    }

    func testAppInactivityPersistenceKeepsOpenStoreSessionsWhenAppKitSnapshotIsEmpty() async throws {
      let container = try HarnessMonitorModelContainer.preview()
      let cacheService = SessionCacheService(modelContainer: container)
      let store = makeStore(modelContainer: container, cacheService: cacheService)
      let delegate = HarnessMonitorAppDelegate()
      let sessionID = PreviewFixtures.summary.sessionId
      XCTAssertTrue(store.sessionIndex.applySessionSummary(PreviewFixtures.summary))

      let storeWindow = NSObject()
      let storeWindowID = ObjectIdentifier(storeWindow)
      store.registerOpenSessionWindow(windowID: storeWindowID, sessionID: sessionID)

      let sessionWindow = makeWindow(origin: .init(x: 24, y: 24))
      let sessionHost = mountHostingContent(
        sessionWindow,
        rootView: AnyView(
          Color.clear
            .frame(width: 16, height: 16)
            .modifier(SessionWindowAppKitBinding(sessionID: sessionID))
            .modifier(SessionWindowTabbing(role: .session, tabTitle: "bart"))
        )
      )
      defer {
        store.unregisterOpenSessionWindow(windowID: storeWindowID)
        cleanUp(windows: [sessionWindow], views: [sessionHost])
      }

      show([sessionWindow])
      drainMainRunLoop()

      NotificationCenter.default.post(
        name: NSWindow.willCloseNotification,
        object: sessionWindow
      )

      XCTAssertTrue(SessionWindowQuitCapture.captureSnapshot().sessionIDs.isEmpty)
      XCTAssertEqual(store.openSessionWindowIDsSnapshot, [sessionID])

      await delegate.persistWindowRestoreStateForAppInactivity(
        using: store,
        userDefaults: userDefaults
      )

      let restorePlan = await store.launchWindowRestorePlan(userDefaults: userDefaults)
      XCTAssertEqual(restorePlan.sessionIDs, [sessionID])
      XCTAssertTrue(restorePlan.tabGroupings.isEmpty)
    }
  }
#endif
