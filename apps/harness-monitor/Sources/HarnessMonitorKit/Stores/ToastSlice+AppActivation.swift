import AppKit
import Foundation

extension ToastSlice {
  public func startObservingAppActivation() {
    guard pauseObservationTask == nil, resumeObservationTask == nil else { return }
    pauseObservationTask = Task { @MainActor [weak self] in
      let stream = NotificationCenter.default.notifications(
        named: NSApplication.didResignActiveNotification
      )
      for await _ in stream {
        guard let self else { return }
        self.pauseTimers()
      }
    }
    resumeObservationTask = Task { @MainActor [weak self] in
      let stream = NotificationCenter.default.notifications(
        named: NSApplication.didBecomeActiveNotification
      )
      for await _ in stream {
        guard let self else { return }
        self.resumeTimers()
      }
    }
  }

  public func stopObservingAppActivation() {
    pauseObservationTask?.cancel()
    resumeObservationTask?.cancel()
    pauseObservationTask = nil
    resumeObservationTask = nil
  }
}
