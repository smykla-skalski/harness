import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Settings scroll restoration")
struct SettingsRestorationTests {
  @Test("Idle and programmatic animation phases keep a pending restore alive")
  func reopenPhasesDoNotCancelPendingRestore() {
    #expect(!SettingsScrollRestorationPhasePolicy.cancelsPendingRestore(.idle))
    #expect(!SettingsScrollRestorationPhasePolicy.cancelsPendingRestore(.animating))
  }

  @Test("Direct user scroll phases cancel a pending restore")
  func userScrollPhasesCancelPendingRestore() {
    #expect(SettingsScrollRestorationPhasePolicy.cancelsPendingRestore(.tracking))
    #expect(SettingsScrollRestorationPhasePolicy.cancelsPendingRestore(.interacting))
    #expect(SettingsScrollRestorationPhasePolicy.cancelsPendingRestore(.decelerating))
  }

  @Test("Settings restoration is not gated by sticky ScrollPosition user ownership")
  func restorationDoesNotUseStickyUserOwnership() throws {
    let source = try settingsRestorationSource()
    #expect(!source.contains("isPositionedByUser"))
    #expect(source.contains(".onScrollPhaseChange"))
    #expect(source.contains("scrollPhase = .idle"))
  }

  private func settingsRestorationSource() throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent(
        "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/Settings"
      )
      .appendingPathComponent("SettingsRestoration.swift")
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
