import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Settings scroll restoration")
struct SettingsRestorationTests {
  @Test("Idle and programmatic animation phases are not user scroll")
  func nonUserPhasesDoNotPersistByThemselves() {
    #expect(!SettingsScrollRestorationPhasePolicy.isUserScroll(.idle))
    #expect(!SettingsScrollRestorationPhasePolicy.isUserScroll(.animating))
  }

  @Test("Direct user scroll phases are user scroll")
  func userScrollPhasesPersist() {
    #expect(SettingsScrollRestorationPhasePolicy.isUserScroll(.tracking))
    #expect(SettingsScrollRestorationPhasePolicy.isUserScroll(.interacting))
    #expect(SettingsScrollRestorationPhasePolicy.isUserScroll(.decelerating))
  }

  @Test("Idle zero geometry does not overwrite a stored scroll offset")
  func idleZeroGeometryDoesNotOverwriteStoredOffset() {
    #expect(
      !SettingsScrollPersistencePolicy.shouldPersist(
        0,
        previousOffset: 96,
        force: false,
        allowsZero: false
      )
    )
  }

  @Test("Confirmed user scroll can persist top")
  func confirmedUserScrollCanPersistTop() {
    #expect(
      SettingsScrollPersistencePolicy.shouldPersist(
        0,
        previousOffset: 96,
        force: true,
        allowsZero: true
      )
    )
  }

  @Test("Nonzero movement uses a coarse persistence threshold")
  func nonzeroMovementUsesPersistenceThreshold() {
    #expect(!SettingsScrollPersistencePolicy.hasMeaningfulMovement(from: 96, to: 116))
    #expect(SettingsScrollPersistencePolicy.hasMeaningfulMovement(from: 96, to: 140))
  }

  @Test("Restore target clamps to available content")
  func restoreTargetClampsToAvailableContent() {
    #expect(
      SettingsScrollPersistencePolicy.restorationTargetOffset(
        storedOffset: 384,
        maxOffset: 120
      ) == 120
    )
  }

  @Test("Pending restore avoids direct geometry callback scroll writes")
  func pendingRestoreAvoidsDirectGeometryCallbackScrollWrites() throws {
    let source = try sourceFile(named: "Views/Settings/SettingsRestoration.swift")
    let waitRange = try #require(source.range(of: "private func waitForPendingRestore("))
    let persistRange = try #require(source.range(of: "private func persistGeometryOffset("))
    let waitBody = String(source[waitRange.lowerBound..<persistRange.lowerBound])

    #expect(!waitBody.contains("requestScroll("))
    #expect(waitBody.contains("scheduleRestoreRetry("))
  }

  @Test("Geometry persistence only tracks confirmed user scroll")
  func geometryPersistenceOnlyTracksConfirmedUserScroll() throws {
    let source = try sourceFile(named: "Views/Settings/SettingsRestoration.swift")
    let persistRange = try #require(source.range(of: "private func persistGeometryOffset("))
    let observedRange = try #require(source.range(of: "private func persistObservedOffset("))
    let persistBody = String(source[persistRange.lowerBound..<observedRange.lowerBound])

    #expect(persistBody.contains("guard isConfirmedUserScroll else {"))
    #expect(!persistBody.contains("|| offset > 0"))
  }

  private func sourceFile(named relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor-macos")
      .appendingPathComponent("Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
