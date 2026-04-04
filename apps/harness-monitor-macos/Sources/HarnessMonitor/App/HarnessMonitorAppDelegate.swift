import HarnessMonitorKit
import AppKit
import Darwin

@MainActor
final class HarnessMonitorAppDelegate: NSObject, NSApplicationDelegate {
  private let handledSignals = [SIGTERM, SIGINT, SIGHUP]
  private var signalSources: [DispatchSourceSignal] = []
  private var terminationTask: Task<Void, Never>?
  private var store: HarnessMonitorStore?

  override init() {
    super.init()
    installSignalHandlers()
  }

  func bind(store: HarnessMonitorStore) {
    self.store = store
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
