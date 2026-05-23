#if canImport(AppKit)
  import AppKit
  import SwiftData
  import SwiftUI
  import XCTest

  @testable import HarnessMonitor
  @testable import HarnessMonitorKit
  @testable import HarnessMonitorUIPreviewable

  @MainActor
  final class SessionWindowQuitCaptureTests: XCTestCase {
    private var previousAllowsAutomaticWindowTabbing = NSWindow.allowsAutomaticWindowTabbing
    var userDefaults: UserDefaults!
    private let suiteName = "io.harnessmonitor.tests.SessionWindowQuitCapture"

    override func setUp() async throws {
      try await super.setUp()
      previousAllowsAutomaticWindowTabbing = NSWindow.allowsAutomaticWindowTabbing
      NSWindow.allowsAutomaticWindowTabbing = false
      SessionWindowAppKitRegistry.shared.resetForTesting()
      DashboardWindowAppKitRegistry.shared.resetForTesting()
      DashboardWindowLifecycleTracker.shared.markClosed()
      userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
      userDefaults.removePersistentDomain(forName: suiteName)
      clearSharedDashboardRestoreState()
    }

    override func tearDown() async throws {
      SessionWindowAppKitRegistry.shared.resetForTesting()
      DashboardWindowAppKitRegistry.shared.resetForTesting()
      DashboardWindowLifecycleTracker.shared.markClosed()
      NSWindow.allowsAutomaticWindowTabbing = previousAllowsAutomaticWindowTabbing
      userDefaults.removePersistentDomain(forName: suiteName)
      userDefaults = nil
      clearSharedDashboardRestoreState()
      try await super.tearDown()
    }

    func testLiveSessionBindingsSurviveTabbingForQuitCapture() throws {
      let sessionA = makeWindow(origin: .zero)
      let sessionB = makeWindow(origin: .init(x: 24, y: 24))
      let bindingA = try mountSessionBinding(sessionA, sessionID: "sess-a")
      let bindingB = try mountSessionBinding(sessionB, sessionID: "sess-b")
      defer { cleanUp(windows: [sessionA, sessionB], views: [bindingA, bindingB]) }

      prepareSharedTabbingIdentity(sessionA, toolbarID: "session-a")
      prepareSharedTabbingIdentity(sessionB, toolbarID: "session-b")
      show([sessionA, sessionB])
      sessionA.addTabbedWindow(sessionB, ordered: .above)
      sessionA.tabGroup?.selectedWindow = sessionB

      let currentBindings = SessionWindowAppKitRegistry.shared.currentBindings()
      XCTAssertEqual(
        Set(currentBindings.map(\.sessionID)),
        Set(["sess-a", "sess-b"])
      )

      let snapshot = SessionWindowQuitCapture.captureSnapshot()

      XCTAssertEqual(snapshot.sessionIDs, Set(["sess-a", "sess-b"]))
      XCTAssertEqual(
        snapshot.groupings,
        [
          HarnessMonitorStore.SessionTabGroupSnapshot(
            ordinal: 0,
            sessionIDs: ["sess-a", "sess-b"],
            foregroundSessionID: "sess-b"
          )
        ]
      )
    }

    func testWillCloseNotificationExcludesSessionWindowFromQuitCaptureImmediately() throws {
      let sessionA = makeWindow(origin: .zero)
      let sessionB = makeWindow(origin: .init(x: 24, y: 24))
      let bindingA = try mountSessionBinding(sessionA, sessionID: "sess-a")
      let bindingB = try mountSessionBinding(sessionB, sessionID: "sess-b")
      defer { cleanUp(windows: [sessionA, sessionB], views: [bindingA, bindingB]) }

      showAndDrain([sessionA, sessionB])
      XCTAssertEqual(
        Set(SessionWindowAppKitRegistry.shared.currentBindings().map(\.sessionID)),
        Set(["sess-a", "sess-b"])
      )

      NotificationCenter.default.post(
        name: NSWindow.willCloseNotification,
        object: sessionB
      )

      let snapshot = SessionWindowQuitCapture.captureSnapshot()

      XCTAssertEqual(snapshot.sessionIDs, ["sess-a"])
      XCTAssertTrue(snapshot.groupings.isEmpty)
    }

    func testLiveDashboardTabStateIncludesSingleTabbedSessionAtQuit() throws {
      let tracker = DashboardWindowLifecycleTracker(userDefaults: userDefaults)
      let dashboardWindow = makeWindow(origin: .zero)
      let sessionWindow = makeWindow(origin: .init(x: 24, y: 24))
      let dashboardBinding = try mountDashboardBinding(dashboardWindow)
      let sessionBinding = try mountSessionBinding(sessionWindow, sessionID: "sess-bart")
      defer {
        cleanUp(
          windows: [dashboardWindow, sessionWindow],
          views: [dashboardBinding, sessionBinding]
        )
      }

      tracker.markOpen()
      prepareSharedTabbingIdentity(dashboardWindow, toolbarID: "dashboard")
      prepareSharedTabbingIdentity(sessionWindow, toolbarID: "session-bart")
      show([dashboardWindow, sessionWindow])
      dashboardWindow.addTabbedWindow(sessionWindow, ordered: .above)
      dashboardWindow.tabGroup?.selectedWindow = dashboardWindow

      tracker.flushOpenAtQuit()

      XCTAssertEqual(
        DashboardWindowLifecycleTracker.tabRestoreStateAtQuit(userDefaults: userDefaults),
        .init(sessionIDs: ["sess-bart"], wasForegroundTab: true)
      )
    }

    func testSwiftUIHostedDashboardFlushStaysOpenWhenSessionTabIsForeground() throws {
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
            .modifier(SessionWindowAppKitBinding(sessionID: "sess-bart"))
            .modifier(SessionWindowTabbing(role: .session, tabTitle: "bart"))
        )
      )
      defer {
        cleanUp(windows: [dashboardWindow, sessionWindow], views: [dashboardHost, sessionHost])
      }

      show([dashboardWindow, sessionWindow])
      drainMainRunLoop()
      XCTAssertTrue(DashboardWindowLifecycleTracker.shared.isOpen)

      dashboardWindow.addTabbedWindow(sessionWindow, ordered: .above)
      dashboardWindow.tabGroup?.selectedWindow = sessionWindow
      drainMainRunLoop()

      DashboardWindowLifecycleTracker.shared.flushOpenAtQuit()

      XCTAssertTrue(DashboardWindowLifecycleTracker.shared.isOpen)
      XCTAssertTrue(DashboardWindowLifecycleTracker.wasOpenAtQuit())
      XCTAssertEqual(
        DashboardWindowLifecycleTracker.tabRestoreStateAtQuit(),
        .init(sessionIDs: ["sess-bart"], wasForegroundTab: false)
      )
    }

    func testSwiftUIHostedReplayRejoinsSingleSessionIntoDashboardTabGroup() async throws {
      let liveDashboard = makeWindow(origin: .zero)
      let liveSession = makeWindow(origin: .init(x: 24, y: 24))
      let liveDashboardHost = mountHostedDashboard(liveDashboard)
      let liveSessionHost = mountHostedSession(
        liveSession,
        sessionID: "sess-bart",
        tabTitle: "bart"
      )
      defer {
        cleanUp(
          windows: [liveDashboard, liveSession],
          views: [liveDashboardHost, liveSessionHost]
        )
      }

      showAndDrain([liveDashboard, liveSession])
      tabTogetherAndDrain(
        liveDashboard,
        sessionWindow: liveSession,
        selectedWindow: liveSession
      )

      DashboardWindowLifecycleTracker.shared.flushOpenAtQuit()
      let dashboardTabRestoreState = DashboardWindowLifecycleTracker.tabRestoreStateAtQuit()
      XCTAssertEqual(
        dashboardTabRestoreState,
        .init(sessionIDs: ["sess-bart"], wasForegroundTab: false)
      )

      cleanUp(windows: [liveDashboard, liveSession], views: [liveDashboardHost, liveSessionHost])
      resetWindowTracking()

      let restoredDashboard = makeWindow(origin: .zero)
      let restoredSession = makeWindow(origin: .init(x: 24, y: 24))
      let restoredDashboardHost = mountHostedDashboard(restoredDashboard)
      let restoredSessionHost = mountHostedSession(
        restoredSession,
        sessionID: "sess-bart",
        tabTitle: "bart"
      )
      defer {
        cleanUp(
          windows: [restoredDashboard, restoredSession],
          views: [restoredDashboardHost, restoredSessionHost]
        )
      }

      let replayRestorePlan = HarnessMonitorInitialWindowRouter.effectiveReplayRestorePlan(
        in: .init(),
        dashboardTabRestoreState: dashboardTabRestoreState,
        liveBoundSessionIDs: []
      )
      XCTAssertEqual(replayRestorePlan.sessionIDs, ["sess-bart"])

      showAndDrain([restoredDashboard, restoredSession])

      let replayGroupings = HarnessMonitorInitialWindowRouter.replayGroupings(
        in: replayRestorePlan,
        shouldRestoreDashboard: true,
        dashboardTabRestoreState: dashboardTabRestoreState
      )
      let replayOutcome = await SessionWindowTabGroupReplayer.replay(
        replayGroupings,
        registry: .shared,
        dashboardWindowProvider: { DashboardWindowAppKitRegistry.shared.window },
        timeout: .milliseconds(400),
        pollInterval: .milliseconds(20)
      )

      let restoredTabGroup = try XCTUnwrap(restoredDashboard.tabGroup)
      XCTAssertEqual(replayOutcome.resolvedGroupCount, 1)
      XCTAssertEqual(replayOutcome.foregroundResolvedCount, 1)
      XCTAssertTrue(restoredSession.tabGroup === restoredTabGroup)
      XCTAssertEqual(restoredTabGroup.windows, [restoredDashboard, restoredSession])
      XCTAssertEqual(restoredTabGroup.selectedWindow, restoredSession)
    }

    func makeWindow(origin: NSPoint) -> NSWindow {
      NSWindow(
        contentRect: .init(origin: origin, size: .init(width: 480, height: 320)),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
      )
    }

    private func mountSessionBinding(
      _ window: NSWindow,
      sessionID: String
    ) throws -> NSView {
      let contentView = try XCTUnwrap(window.contentView)
      let view = SessionWindowAppKitBindingNSView(sessionID: sessionID)
      contentView.addSubview(view)
      return view
    }

    private func mountDashboardBinding(_ window: NSWindow) throws -> NSView {
      let contentView = try XCTUnwrap(window.contentView)
      let view = DashboardWindowAppKitBindingNSView()
      contentView.addSubview(view)
      return view
    }

    func mountHostingContent(_ window: NSWindow, rootView: AnyView) -> NSView {
      let hostingView = NSHostingView(rootView: rootView)
      window.contentView = hostingView
      return hostingView
    }

    private func mountHostedDashboard(_ window: NSWindow) -> NSView {
      mountHostingContent(
        window,
        rootView: AnyView(
          Color.clear
            .frame(width: 16, height: 16)
            .modifier(DashboardWindowAppKitBinding())
            .modifier(SessionWindowTabbing(role: .dashboard))
            .modifier(DashboardWindowLifecycleModifier())
        )
      )
    }

    private func mountHostedSession(
      _ window: NSWindow,
      sessionID: String,
      tabTitle: String
    ) -> NSView {
      mountHostingContent(
        window,
        rootView: AnyView(
          Color.clear
            .frame(width: 16, height: 16)
            .modifier(SessionWindowAppKitBinding(sessionID: sessionID))
            .modifier(SessionWindowTabbing(role: .session, tabTitle: tabTitle))
        )
      )
    }

    private func prepareSharedTabbingIdentity(_ window: NSWindow, toolbarID: String) {
      window.toolbar = NSToolbar(identifier: toolbarID)
      SessionWindowTabbingSupport.prepareWindowForTabbing(window, preference: .always)
    }

    func show(_ windows: [NSWindow]) {
      for window in windows.dropLast() {
        window.orderFront(nil)
      }
      windows.last?.makeKeyAndOrderFront(nil)
    }

    func drainMainRunLoop() {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    }

    private func showAndDrain(_ windows: [NSWindow]) {
      show(windows)
      drainMainRunLoop()
    }

    private func tabTogetherAndDrain(
      _ dashboardWindow: NSWindow,
      sessionWindow: NSWindow,
      selectedWindow: NSWindow
    ) {
      dashboardWindow.addTabbedWindow(sessionWindow, ordered: .above)
      dashboardWindow.tabGroup?.selectedWindow = selectedWindow
      drainMainRunLoop()
    }

    private func clearSharedDashboardRestoreState() {
      UserDefaults.standard.removeObject(forKey: DashboardWindowLifecycleTracker.openAtQuitKey)
      UserDefaults.standard.removeObject(
        forKey: DashboardWindowLifecycleTracker.tabbedSessionIDsAtQuitKey
      )
      UserDefaults.standard.removeObject(
        forKey: DashboardWindowLifecycleTracker.wasForegroundTabAtQuitKey
      )
    }

    private func resetWindowTracking() {
      SessionWindowAppKitRegistry.shared.resetForTesting()
      DashboardWindowAppKitRegistry.shared.resetForTesting()
      DashboardWindowLifecycleTracker.shared.markClosed()
    }

    @MainActor
    func makeStore(
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

    func cleanUp(windows: [NSWindow], views: [NSView]) {
      for view in views {
        view.removeFromSuperview()
      }
      for window in windows.reversed() {
        window.orderOut(nil)
      }
    }
  }
#endif
