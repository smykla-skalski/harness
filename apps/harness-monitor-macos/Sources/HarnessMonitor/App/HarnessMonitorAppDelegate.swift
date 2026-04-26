import AppKit
import Darwin
import HarnessMonitorKit
import HarnessMonitorUIPreviewable

@MainActor
final class HarnessMonitorAppDelegate: NSObject, NSApplicationDelegate {
  private static let uiTestingBundleIdentifier = "io.harnessmonitor.app.ui-testing"
  private static let uiTestsEnvironmentKey = "HARNESS_MONITOR_UI_TESTS"
  private let handledSignals = [SIGTERM, SIGINT, SIGHUP]
  private let hidesDockIconForPerfRuns =
    ProcessInfo.processInfo.environment["HARNESS_MONITOR_PERF_HIDE_DOCK_ICON"] == "1"
  private let isUITestRun: Bool = {
    let environment = HarnessMonitorAppDelegate.launchEnvironment()
    return environment[HarnessMonitorAppDelegate.uiTestsEnvironmentKey] == "1"
  }()
  private let launchMode = HarnessMonitorLaunchMode(
    environment: HarnessMonitorAppDelegate.launchEnvironment()
  )
  private let mcpStartupController = HarnessMonitorMCPStartupController()
  private var signalSources: [DispatchSourceSignal] = []
  private var terminationTask: Task<Void, Never>?
  private var store: HarnessMonitorStore?

  override init() {
    super.init()
    installSignalHandlers()
    let environment = Self.launchEnvironment()
    let isUITestRun = environment[Self.uiTestsEnvironmentKey] == "1"
    let keepsAnimations = environment["HARNESS_MONITOR_KEEP_ANIMATIONS"] == "1"
    if isUITestRun && !keepsAnimations {
      disableAnimationsForUITesting()
    }
  }

  func applicationWillFinishLaunching(_ notification: Notification) {
    NSWindow.allowsAutomaticWindowTabbing = false
    guard hidesDockIconForPerfRuns else {
      return
    }
    NSApplication.shared.setActivationPolicy(.accessory)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    mcpStartupController.start()
    guard !hidesDockIconForPerfRuns else {
      return
    }
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(300))
      guard !hasVisibleMainWindow() else {
        return
      }
      HarnessMonitorMainWindowLauncher.shared.openMainWindow?()
    }
  }

  @MainActor
  private func hasVisibleMainWindow() -> Bool {
    NSApplication.shared.windows.contains { window in
      guard window.isVisible else {
        return false
      }
      let identifier = window.identifier?.rawValue ?? ""
      return identifier.contains(HarnessMonitorWindowID.main)
    }
  }

  func bind(store: HarnessMonitorStore) {
    self.store = store
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
      MainActor.assumeIsolated {
        self?.configureWindowForUITesting(window)
      }
    }
    for window in NSApplication.shared.windows {
      configureWindowForUITesting(window)
    }
  }

  private func configureWindowForUITesting(_ window: NSWindow?) {
    window?.animationBehavior = .none
  }

  func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool {
    if isUITestRun {
      _ = sender
      return true
    }
    let storedValue =
      UserDefaults.standard.object(
        forKey: SupervisorPreferencesDefaults.runInBackgroundKey
      ) as? Bool
    let runInBackground = storedValue ?? SupervisorPreferencesDefaults.runInBackgroundDefault
    _ = sender
    return !runInBackground
  }

  func applicationDidResignActive(_ notification: Notification) {
    let body: () -> Void = { [self] in
      guard launchMode == .live, let store else {
        return
      }
      guard shouldSuspendLiveConnectionOnResignActive() else {
        return
      }

      Task { @MainActor [weak self] in
        guard self?.terminationTask == nil else {
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

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if isUITestRun {
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
    if isUITestRun {
      #if HARNESS_FEATURE_OTEL
        HarnessMonitorTelemetry.shared.shutdown()
      #endif
      terminateProcess(for: handledSignal)
      return
    }
    guard terminationTask == nil else {
      return
    }

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

  private func shouldSuspendLiveConnectionOnResignActive() -> Bool {
    HarnessMonitorAppVisibilityPolicy.shouldSuspendLiveConnection(
      appIsHidden: NSApplication.shared.isHidden,
      hasVisibleNonMiniaturizedWindows: NSApplication.shared.windows.contains { window in
        window.isVisible && !window.isMiniaturized
      }
    )
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

  private static func isBlank(_ rawValue: String?) -> Bool {
    rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
  }
}
