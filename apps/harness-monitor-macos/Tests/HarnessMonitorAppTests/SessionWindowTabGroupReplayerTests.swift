#if canImport(AppKit)
  import AppKit
  import XCTest

  @testable import HarnessMonitor
  @testable import HarnessMonitorKit
  @testable import HarnessMonitorUIPreviewable

  @MainActor
  final class SessionWindowTabGroupReplayerTests: XCTestCase {
    func testAccessorAppliesSharedTabbingIdentityBeforeToolbarExists() throws {
      let window = try XCTUnwrap(makeSessionWindows(count: 1).first)
      let accessor = SessionWindowTabbingAccessorView()
      let contentView = try XCTUnwrap(window.contentView)
      accessor.configuration = .init(
        role: .session,
        preference: .always,
        tabTitle: "Session Alpha",
        pendingDecisionCount: 1,
        pendingDecisionSeverity: .warn
      )
      defer {
        accessor.removeFromSuperview()
        window.orderOut(nil)
      }

      contentView.addSubview(accessor)
      accessor.applyWindowTabbing()

      XCTAssertNil(window.toolbar)
      XCTAssertEqual(window.tabbingIdentifier, SessionWindowTabbingSupport.tabbingIdentifier)
      XCTAssertEqual(window.tabbingMode, .preferred)
      XCTAssertEqual(window.titlebarSeparatorStyle, .none)
      XCTAssertNotNil(window.tab.attributedTitle)
    }

    func testAttemptMergeLeavesLateSessionUnresolvedUntilItHasSharedTabbingIdentity() throws {
      let registry = SessionWindowAppKitRegistry()
      let windows = makeSessionWindows(count: 3)
      defer { cleanUp(windows, registry: registry) }

      let sessionIDs = ["sess-a", "sess-b", "sess-c"]
      bind(windows, to: sessionIDs, registry: registry)
      prepareSharedTabbingIdentity(windows[0])
      prepareSharedTabbingIdentity(windows[1])
      show(windows)

      let grouping = HarnessMonitorStore.SessionTabGroupSnapshot(
        ordinal: 0,
        sessionIDs: sessionIDs,
        foregroundSessionID: "sess-b"
      )
      let outcome = SessionWindowTabGroupReplayer.attemptMerge(
        grouping,
        registry: registry
      )

      XCTAssertFalse(outcome.resolved)
      XCTAssertFalse(outcome.foregroundResolved)
      XCTAssertEqual(outcome.missingTabReadySessionIDs, ["sess-c"])

      let partialGroup = try XCTUnwrap(windows[0].tabGroup)
      XCTAssertTrue(partialGroup === windows[1].tabGroup)
      XCTAssertFalse(partialGroup === windows[2].tabGroup)
    }

    func testReplayRetriesLateThirdSessionUntilItHasSharedTabbingIdentity() async throws {
      let registry = SessionWindowAppKitRegistry()
      let windows = makeSessionWindows(count: 3)
      defer { cleanUp(windows, registry: registry) }

      let sessionIDs = ["sess-a", "sess-b", "sess-c"]
      bind(windows, to: sessionIDs, registry: registry)
      prepareSharedTabbingIdentity(windows[0])
      prepareSharedTabbingIdentity(windows[1])
      show(windows)

      let grouping = HarnessMonitorStore.SessionTabGroupSnapshot(
        ordinal: 0,
        sessionIDs: sessionIDs,
        foregroundSessionID: "sess-b"
      )

      let replayTask = Task { @MainActor in
        await SessionWindowTabGroupReplayer.replay(
          [grouping],
          registry: registry,
          timeout: .milliseconds(400),
          pollInterval: .milliseconds(20)
        )
      }

      try await Task.sleep(for: .milliseconds(80))
      prepareSharedTabbingIdentity(windows[2])

      let outcome = await replayTask.value
      let resolvedGroup = try XCTUnwrap(windows[0].tabGroup)

      XCTAssertEqual(outcome.resolvedGroupCount, 1)
      XCTAssertEqual(outcome.foregroundResolvedCount, 1)
      XCTAssertEqual(outcome.tabReadySessionIDCount, 3)
      XCTAssertFalse(outcome.toolbarsReady)
      XCTAssertGreaterThan(outcome.attempts, 1)
      XCTAssertTrue(resolvedGroup === windows[1].tabGroup)
      XCTAssertTrue(resolvedGroup === windows[2].tabGroup)
      XCTAssertTrue(
        SessionWindowTabGroupReplayer.isGroupingResolved(
          grouping,
          registry: registry
        )
      )
      XCTAssertEqual(resolvedGroup.selectedWindow, windows[1])
    }

    func testReplayMixedDashboardGroupingKeepsDashboardFirst() async throws {
      let registry = SessionWindowAppKitRegistry()
      let windows = makeSessionWindows(count: 3)
      let dashboardWindow = windows[0]
      let sessionWindows = Array(windows.dropFirst())
      defer { cleanUp(windows, registry: registry) }

      let sessionIDs = ["sess-a", "sess-b"]
      bind(sessionWindows, to: sessionIDs, registry: registry)
      prepareSharedTabbingIdentity(dashboardWindow)
      prepareSharedTabbingIdentity(sessionWindows[0])
      prepareSharedTabbingIdentity(sessionWindows[1])
      show(windows)

      let grouping = HarnessMonitorStore.SessionTabGroupSnapshot(
        ordinal: 0,
        sessionIDs: sessionIDs,
        foregroundSessionID: "sess-b",
        includesDashboard: true
      )

      let outcome = await SessionWindowTabGroupReplayer.replay(
        [grouping],
        registry: registry,
        dashboardWindowProvider: { dashboardWindow },
        timeout: .milliseconds(400),
        pollInterval: .milliseconds(20)
      )

      let resolvedGroup = try XCTUnwrap(dashboardWindow.tabGroup)
      XCTAssertEqual(outcome.resolvedGroupCount, 1)
      XCTAssertEqual(outcome.foregroundResolvedCount, 1)
      XCTAssertTrue(resolvedGroup === sessionWindows[0].tabGroup)
      XCTAssertTrue(resolvedGroup === sessionWindows[1].tabGroup)
      XCTAssertEqual(resolvedGroup.windows.first, dashboardWindow)
      XCTAssertEqual(resolvedGroup.selectedWindow, sessionWindows[1])
    }

    func testReplayMixedDashboardGroupingRestoresDashboardForeground() async throws {
      let registry = SessionWindowAppKitRegistry()
      let windows = makeSessionWindows(count: 2)
      let dashboardWindow = windows[0]
      let sessionWindow = windows[1]
      defer { cleanUp(windows, registry: registry) }

      bind([sessionWindow], to: ["sess-a"], registry: registry)
      prepareSharedTabbingIdentity(dashboardWindow)
      prepareSharedTabbingIdentity(sessionWindow)
      show(windows)

      let grouping = HarnessMonitorStore.SessionTabGroupSnapshot(
        ordinal: 0,
        sessionIDs: ["sess-a"],
        includesDashboard: true,
        dashboardWasForeground: true
      )

      let outcome = await SessionWindowTabGroupReplayer.replay(
        [grouping],
        registry: registry,
        dashboardWindowProvider: { dashboardWindow },
        timeout: .milliseconds(400),
        pollInterval: .milliseconds(20)
      )

      let resolvedGroup = try XCTUnwrap(dashboardWindow.tabGroup)
      XCTAssertEqual(outcome.resolvedGroupCount, 1)
      XCTAssertEqual(outcome.foregroundResolvedCount, 1)
      XCTAssertTrue(resolvedGroup === sessionWindow.tabGroup)
      XCTAssertEqual(resolvedGroup.windows.first, dashboardWindow)
      XCTAssertEqual(resolvedGroup.selectedWindow, dashboardWindow)
    }

    private func makeSessionWindows(count: Int) -> [NSWindow] {
      (0..<count).map { index in
        NSWindow(
          contentRect: .init(x: CGFloat(index * 24), y: CGFloat(index * 24), width: 480, height: 320),
          styleMask: [.titled, .closable, .resizable],
          backing: .buffered,
          defer: false
        )
      }
    }

    private func bind(
      _ windows: [NSWindow],
      to sessionIDs: [String],
      registry: SessionWindowAppKitRegistry
    ) {
      for (window, sessionID) in zip(windows, sessionIDs) {
        registry.bind(window: window, sessionID: sessionID)
      }
    }

    private func prepareSharedTabbingIdentity(_ window: NSWindow) {
      SessionWindowTabbingSupport.prepareWindowForTabbing(window, preference: .always)
    }

    private func show(_ windows: [NSWindow]) {
      for window in windows.dropLast() {
        window.orderFront(nil)
      }
      windows.last?.makeKeyAndOrderFront(nil)
    }

    private func cleanUp(
      _ windows: [NSWindow],
      registry: SessionWindowAppKitRegistry
    ) {
      for window in windows.reversed() {
        registry.unbind(window: window)
        window.orderOut(nil)
      }
    }
  }
#endif
