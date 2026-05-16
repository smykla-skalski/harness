#if canImport(AppKit)
  import AppKit
  import XCTest

  @testable import HarnessMonitor
  @testable import HarnessMonitorKit
  @testable import HarnessMonitorUIPreviewable

  @MainActor
  final class SessionWindowTabGroupReplayerTests: XCTestCase {
    func testAttemptMergeLeavesLateSessionUnresolvedUntilItIsTabReady() throws {
      let registry = SessionWindowAppKitRegistry()
      let windows = makeSessionWindows(count: 3)
      defer { cleanUp(windows, registry: registry) }

      let sessionIDs = ["sess-a", "sess-b", "sess-c"]
      bind(windows, to: sessionIDs, registry: registry)
      prepareTabReady(windows[0], toolbarID: "toolbar-a")
      prepareTabReady(windows[1], toolbarID: "toolbar-b")
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

    func testReplayRetriesLateThirdSessionUntilTheGroupConverges() async throws {
      let registry = SessionWindowAppKitRegistry()
      let windows = makeSessionWindows(count: 3)
      defer { cleanUp(windows, registry: registry) }

      let sessionIDs = ["sess-a", "sess-b", "sess-c"]
      bind(windows, to: sessionIDs, registry: registry)
      prepareTabReady(windows[0], toolbarID: "toolbar-a")
      prepareTabReady(windows[1], toolbarID: "toolbar-b")
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
      prepareTabReady(windows[2], toolbarID: "toolbar-c")

      let outcome = await replayTask.value
      let resolvedGroup = try XCTUnwrap(windows[0].tabGroup)

      XCTAssertEqual(outcome.resolvedGroupCount, 1)
      XCTAssertEqual(outcome.foregroundResolvedCount, 1)
      XCTAssertEqual(outcome.tabReadySessionIDCount, 3)
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

    private func prepareTabReady(
      _ window: NSWindow,
      toolbarID: String
    ) {
      window.toolbar = NSToolbar(identifier: toolbarID)
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
