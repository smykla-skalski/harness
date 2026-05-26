import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Clipboard automation monitor")
@MainActor
struct ClipboardAutomationMonitorTests {
  @Test("Stop clears runtime state")
  func stopClearsRuntimeState() {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let center = AutomationPolicyCenter(
      fileURL: directory.appendingPathComponent("policies.json")
    )
    let monitor = ClipboardAutomationMonitor()

    center.updateClipboardRuntimeState(.watching)
    monitor.stop(center: center)

    #expect(center.clipboardRuntimeState == .off)
  }

  @Test("Stale delayed change counts are ignored")
  func staleDelayedChangeCountsAreIgnored() {
    #expect(
      ClipboardAutomationMonitor.shouldEvaluateObservedChange(
        observedChangeCount: 12,
        currentChangeCount: 12
      )
    )
    #expect(
      !ClipboardAutomationMonitor.shouldEvaluateObservedChange(
        observedChangeCount: 12,
        currentChangeCount: 13
      )
    )
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "ClipboardAutomationMonitorTests-\(UUID().uuidString)",
        isDirectory: true
      )
  }
}
