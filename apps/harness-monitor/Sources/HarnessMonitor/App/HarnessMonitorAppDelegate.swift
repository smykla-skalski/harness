import AppKit
import Darwin
import HarnessMonitorCloudKit
import HarnessMonitorIntents
import HarnessMonitorKit
import HarnessMonitorUIPreviewable

@MainActor
final class HarnessMonitorAppDelegate: NSObject, NSApplicationDelegate {
  private static let uiTestingBundleIdentifier = "io.harnessmonitor.app.ui-testing"
  private static let uiTestsEnvironmentKey = "HARNESS_MONITOR_UI_TESTS"
  private let handledSignals = [SIGTERM, SIGINT, SIGHUP]
  private let hidesDockIconForPerfRuns =
    ProcessInfo.processInfo.environment["HARNESS_MONITOR_PERF_HIDE_DOCK_ICON"] == "1"
  private let isTestHarnessRun = HarnessMonitorAppDelegate.isCurrentTestHarnessRun()
  private let launchMode = HarnessMonitorLaunchMode(
    environment: HarnessMonitorAppDelegate.launchEnvironment()
  )
  private let standardErrorWarningCapture = HarnessMonitorStandardErrorWarningCapture()
  private let mcpStartupController = HarnessMonitorMCPStartupController()
  private var signalSources: [DispatchSourceSignal] = []
  private var terminationTask: Task<Void, Never>?
  private var store: HarnessMonitorStore?
  private let accountObserver = CloudKitAccountChangeObserver(
    handler: CloudKitAccountChangeHandler.live()
  )
  private let needsMePump = NeedsMeCountCloudKitPump.shared

  override init() {
    super.init()
    // Preview/playground shells run an ad-hoc signed copy of the bundle from
    // /private/tmp and tear down on a non-main thread. dup2(STDERR), MCP
    // background tasks, and SIGTERM/SIGINT/SIGHUP DispatchSource handlers
    // either collide with Xcode's preview IPC pipe or fire main-actor blocks
    // off the main queue, both of which trip libdispatch BUG and abort the
    // canvas. Restrict every live-only side effect to shipping launches.
    if runsLiveSideEffects {
      standardErrorWarningCapture.start()
      installSignalHandlers()
    }
    let environment = Self.launchEnvironment()
    let keepsAnimations = environment["HARNESS_MONITOR_KEEP_ANIMATIONS"] == "1"
    if isTestHarnessRun && !keepsAnimations {
      disableAnimationsForUITesting()
    }
  }

  private var runsLiveSideEffects: Bool {
    launchMode == .live && !isTestHarnessRun
  }

  func applicationWillFinishLaunching(_ notification: Notification) {
    if hidesDockIconForPerfRuns {
      NSApplication.shared.setActivationPolicy(.accessory)
      return
    }
    NSApplication.shared.setActivationPolicy(.regular)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    _ = notification
    // MCP startup spins up background HTTP/IPC tasks that bind sandboxed
    // services - those abort under the preview shell and the user-facing
    // symptom is "Harness Monitor crashed" in the canvas.
    if runsLiveSideEffects {
      mcpStartupController.start()
      accountObserver.start()
      needsMePump.start()
    }
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    _ = sender
    guard Self.shouldRequestMainWindowOnReopen(hasVisibleWindows: flag) else {
      return true
    }
    HarnessMonitorMainWindowLauncher.shared.requestOpenMainWindow()
    return false
  }

  func bind(store: HarnessMonitorStore) {
    self.store = store
    // The startup controller owns MCP runtime/recovery truth. The store only mirrors
    // snapshots so toolbar, banner, settings, and feedback stay passive observers.
    mcpStartupController.statusDidChange = { [weak store] status in
      store?.updateMCPStatus(status)
    }
    store.updateMCPStatus(mcpStartupController.statusSnapshot)
  }

  private func disableAnimationsForUITesting() {
    NSAnimationContext.beginGrouping()
    NSAnimationContext.current.duration = 0
    NSAnimationContext.current.allowsImplicitAnimation = false
    NSAnimationContext.endGrouping()
    NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      let window = notification.object as? NSWindow
      // Hop explicitly. `MainActor.assumeIsolated` would trap if the
      // block ever fires off-main on macOS 26.
      Task { @MainActor [weak self] in
        self?.configureWindowForUITesting(window)
      }
    }
    for window in NSApplication.shared.windows {
      configureWindowForUITesting(window)
    }
  }

  private func configureWindowForUITesting(_ window: NSWindow?) {
    guard let window else {
      return
    }
    guard isTestHarnessRun else {
      window.animationBehavior = .none
      return
    }
    window.animationBehavior = .none
  }

  func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool {
    _ = sender
    return Self.shouldTerminateAfterLastWindowClosed(
      isTestHarnessRun: isTestHarnessRun
    )
  }

  nonisolated static func shouldTerminateAfterLastWindowClosed(
    isTestHarnessRun: Bool
  ) -> Bool {
    isTestHarnessRun
  }

  nonisolated static func shouldRequestMainWindowOnReopen(
    hasVisibleWindows: Bool
  ) -> Bool {
    !hasVisibleWindows
  }

  func applicationDidResignActive(_ notification: Notification) {
    let body: () -> Void = { [self] in
      guard launchMode == .live, let store else {
        return
      }

      Task { @MainActor [weak self] in
        guard let self, self.terminationTask == nil else {
          return
        }
        await self.persistWindowRestoreStateForAppInactivity(using: store)
        guard self.shouldSuspendLiveConnectionOnResignActive() else {
          return
        }
        await store.suspendLiveConnectionForAppInactivity()
      }
    }
    #if HARNESS_FEATURE_OTEL
      HarnessMonitorTelemetry.shared.withAppLifecycleTransition(
        event: "resign_active",
        launchMode: launchMode.rawValue,
        body
      )
    #else
      body()
    #endif
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    let body: () -> Void = { [self] in
      guard launchMode == .live, let store else {
        return
      }

      Task { @MainActor [weak self] in
        guard self?.terminationTask == nil else {
          return
        }
        await store.resumeLiveConnectionAfterAppActivation()
      }
    }
    #if HARNESS_FEATURE_OTEL
      HarnessMonitorTelemetry.shared.withAppLifecycleTransition(
        event: "become_active",
        launchMode: launchMode.rawValue,
        body
      )
    #else
      body()
    #endif
  }

  func persistWindowRestoreStateForAppInactivity(
    using store: HarnessMonitorStore,
    userDefaults: UserDefaults = .standard
  ) async {
    let quitSnapshot = sessionWindowQuitSnapshot(using: store)
    DashboardWindowLifecycleTracker.shared.flushOpenAtQuit(userDefaults: userDefaults)
    await store.persistSessionWindowRestoreSnapshot(
      quitSnapshot,
      userDefaults: userDefaults
    )
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if isTestHarnessRun {
      _ = sender
      #if HARNESS_FEATURE_OTEL
        HarnessMonitorTelemetry.shared.shutdown()
      #endif
      return .terminateNow
    }
    guard terminationTask == nil else {
      return .terminateLater
    }
    guard let store else {
      #if HARNESS_FEATURE_OTEL
        HarnessMonitorTelemetry.shared.shutdown()
      #endif
      return .terminateNow
    }

    let quitSnapshot = SessionWindowQuitCapture.captureSnapshot()
    store.beginSessionWindowTerminationSnapshot(quitSnapshot: quitSnapshot)
    DashboardWindowLifecycleTracker.shared.flushOpenAtQuit()
    terminationTask = Task { @MainActor [weak self] in
      await self?.prepareForTermination(using: store)
      self?.terminationTask = nil
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  private func installSignalHandlers() {
    guard signalSources.isEmpty else {
      return
    }

    for handledSignal in handledSignals {
      signal(handledSignal, SIG_IGN)
      let source = DispatchSource.makeSignalSource(
        signal: handledSignal,
        queue: .main
      )
      source.setEventHandler { [weak self] in
        self?.handleSignalTermination(handledSignal)
      }
      source.resume()
      signalSources.append(source)
    }
  }

  private func handleSignalTermination(_ handledSignal: Int32) {
    if isTestHarnessRun {
      #if HARNESS_FEATURE_OTEL
        HarnessMonitorTelemetry.shared.shutdown()
      #endif
      terminateProcess(for: handledSignal)
      return
    }
    guard terminationTask == nil else {
      return
    }

    let quitSnapshot = SessionWindowQuitCapture.captureSnapshot()
    store?.beginSessionWindowTerminationSnapshot(quitSnapshot: quitSnapshot)
    DashboardWindowLifecycleTracker.shared.flushOpenAtQuit()
    terminationTask = Task { @MainActor [weak self] in
      if let self {
        await self.prepareForTermination(using: self.store)
      } else {
        #if HARNESS_FEATURE_OTEL
          HarnessMonitorTelemetry.shared.shutdown()
        #endif
      }
      self?.terminationTask = nil
      self?.terminateProcess(for: handledSignal)
    }
  }

  private func prepareForTermination(using store: HarnessMonitorStore?) async {
    if let store {
      await store.prepareForTermination()
    }
    await mcpStartupController.stop()
    #if HARNESS_FEATURE_OTEL
      HarnessMonitorTelemetry.shared.shutdown()
    #endif
  }

  private func terminateProcess(for handledSignal: Int32) {
    signal(handledSignal, SIG_DFL)
    kill(getpid(), handledSignal)
    _exit(128 + handledSignal)
  }

  private func sessionWindowQuitSnapshot(
    using store: HarnessMonitorStore
  ) -> HarnessMonitorStore.SessionWindowQuitSnapshot {
    let appKitSnapshot = SessionWindowQuitCapture.captureSnapshot()
    return HarnessMonitorStore.SessionWindowQuitSnapshot(
      sessionIDs: appKitSnapshot.sessionIDs.union(store.openSessionWindowIDsSnapshot),
      groupings: appKitSnapshot.groupings
    )
  }

  private func shouldSuspendLiveConnectionOnResignActive() -> Bool {
    HarnessMonitorAppVisibilityPolicy.shouldSuspendLiveConnection(
      appIsHidden: NSApplication.shared.isHidden,
      hasVisibleNonMiniaturizedWindows: NSApplication.shared.windows.contains { window in
        window.isVisible && !window.isMiniaturized
      },
      keepsLiveConnectionInBackground: supervisorRunInBackgroundEnabled
    )
  }

  private var supervisorRunInBackgroundEnabled: Bool {
    let storedValue =
      UserDefaults.standard.object(
        forKey: SupervisorSettingsDefaults.runInBackgroundKey
      ) as? Bool
    return storedValue ?? SupervisorSettingsDefaults.runInBackgroundDefault
  }

  private static func launchEnvironment() -> [String: String] {
    let environment = ProcessInfo.processInfo.environment
    guard Bundle.main.bundleIdentifier == uiTestingBundleIdentifier else {
      return environment
    }

    var values = environment
    values[uiTestsEnvironmentKey] = "1"
    if isBlank(values[HarnessMonitorLaunchMode.environmentKey]) {
      values[HarnessMonitorLaunchMode.environmentKey] = HarnessMonitorLaunchMode.preview.rawValue
    }
    return values
  }

  nonisolated static func isCurrentTestHarnessRun(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    bundleIdentifier: String? = Bundle.main.bundleIdentifier,
    processName: String = ProcessInfo.processInfo.processName,
    loadedBundlePaths: [String] = Bundle.allBundles.map(\.bundlePath)
  ) -> Bool {
    isTestHarnessRun(
      environment: environment,
      bundleIdentifier: bundleIdentifier,
      processName: processName,
      loadedBundlePaths: loadedBundlePaths
    )
  }

  nonisolated static func isTestHarnessRun(
    environment: [String: String],
    bundleIdentifier: String?,
    processName: String,
    loadedBundlePaths: [String] = []
  ) -> Bool {
    environment["HARNESS_MONITOR_UI_TESTS"] == "1"
      || environment["XCTestConfigurationFilePath"] != nil
      || environment["XCInjectBundle"] != nil
      || environment["XCInjectBundleInto"] != nil
      || bundleIdentifier == "io.harnessmonitor.app.ui-testing"
      || processName == "xctest"
      || loadedBundlePaths.contains { $0.hasSuffix(".xctest") }
  }

  private static func isBlank(_ rawValue: String?) -> Bool {
    rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
  }
}
