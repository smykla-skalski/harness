import AppKit
import Darwin
import HarnessMonitorKit

@MainActor
final class HarnessMonitorAppDelegate: NSObject, NSApplicationDelegate {
  private let handledSignals = [SIGTERM, SIGINT, SIGHUP]
  private let hidesDockIconForPerfRuns =
    ProcessInfo.processInfo.environment["HARNESS_MONITOR_PERF_HIDE_DOCK_ICON"] == "1"
  private var signalSources: [DispatchSourceSignal] = []
  private var terminationTask: Task<Void, Never>?
  private var store: HarnessMonitorStore?

  override init() {
    super.init()
    installSignalHandlers()
    if ProcessInfo.processInfo.environment["HARNESS_MONITOR_UI_TESTS"] == "1"
      && ProcessInfo.processInfo.environment["HARNESS_MONITOR_KEEP_ANIMATIONS"] != "1"
    {
      disableAnimationsForUITesting()
    }
  }

  func applicationWillFinishLaunching(_ notification: Notification) {
    guard hidesDockIconForPerfRuns else {
      return
    }
    NSApplication.shared.setActivationPolicy(.accessory)
  }

  func bind(store: HarnessMonitorStore) {
    self.store = store
  }

  private func disableAnimationsForUITesting() {
    NSAnimationContext.current.duration = 0
    NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification,
      object: nil,
      queue: .main
    ) { notification in
      let window = notification.object as? NSWindow
      MainActor.assumeIsolated {
        window?.animationBehavior = .none
      }
    }
    for window in NSApplication.shared.windows {
      window.animationBehavior = .none
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool {
    true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard terminationTask == nil else {
      return .terminateLater
    }
    guard let store else {
      return .terminateNow
    }

    terminationTask = Task { @MainActor [weak self] in
      await store.prepareForTermination()
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
    guard terminationTask == nil else {
      return
    }

    terminationTask = Task { @MainActor [weak self] in
      if let store = self?.store {
        await store.prepareForTermination()
      }
      self?.terminationTask = nil
      self?.terminateProcess(for: handledSignal)
    }
  }

  private func terminateProcess(for handledSignal: Int32) {
    signal(handledSignal, SIG_DFL)
    kill(getpid(), handledSignal)
    _exit(128 + handledSignal)
  }
}
