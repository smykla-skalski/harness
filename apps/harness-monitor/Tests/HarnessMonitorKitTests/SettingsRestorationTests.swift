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
    let scheduleRange = try #require(source.range(of: "private func scheduleRestoreRetry("))
    let waitBody = String(source[waitRange.lowerBound..<scheduleRange.lowerBound])

    #expect(!waitBody.contains("requestScroll("))
    #expect(waitBody.contains("scheduleRestoreRetry("))
  }

  @Test("Restore requests use the AppKit applicator as the single scroll write path")
  func restoreRequestsUseSingleWritePath() throws {
    let source = try sourceFile(named: "Views/Settings/SettingsRestoration.swift")
    let requestRange = try #require(source.range(of: "private func requestScroll(to offset: CGFloat)"))
    let handleRange = try #require(source.range(of: "private func handleScrollPhaseChange("))
    let requestBody = String(source[requestRange.lowerBound..<handleRange.lowerBound])

    #expect(!source.contains(".scrollPosition($scrollPosition)"))
    #expect(requestBody.contains("restoreApplicatorRequest = SettingsScrollRestoreRequest("))
    #expect(!requestBody.contains("scrollPosition.scrollTo("))
  }

  @Test("Zero offsets do not create restore applicator requests")
  func zeroOffsetsDoNotCreateRestoreApplicatorRequests() throws {
    let source = try sourceFile(named: "Views/Settings/SettingsRestoration.swift")
    let restoreRange = try #require(source.range(of: "private func restoreScrollPosition("))
    let clearRange = try #require(source.range(of: "private func clearScrollRequest("))
    let restoreBody = String(source[restoreRange.lowerBound..<clearRange.lowerBound])

    #expect(restoreBody.contains("guard offset > 0 else"))
    #expect(restoreBody.contains("clearScrollRequest()"))
    #expect(restoreBody.contains("return"))
  }

  @Test("Geometry persistence only tracks confirmed user scroll")
  func geometryPersistenceOnlyTracksConfirmedUserScroll() throws {
    let source = try sourceFile(named: "Views/Settings/SettingsRestoration.swift")
    let persistRange = try #require(source.range(of: "private func persistGeometryOffset("))
    let bufferRange = try #require(source.range(of: "private func bufferObservedOffset("))
    let persistBody = String(source[persistRange.lowerBound..<bufferRange.lowerBound])

    #expect(persistBody.contains("guard isConfirmedUserScroll else {"))
    #expect(!persistBody.contains("|| offset > 0"))
  }

  @Test("Geometry persistence buffers instead of writing UserDefaults")
  func geometryPersistenceBuffersInsteadOfWritingDefaults() throws {
    let source = try sourceFile(named: "Views/Settings/SettingsRestoration.swift")
    let persistRange = try #require(source.range(of: "private func persistGeometryOffset("))
    let bufferRange = try #require(source.range(of: "private func bufferObservedOffset("))
    let persistBody = String(source[persistRange.lowerBound..<bufferRange.lowerBound])

    #expect(persistBody.contains("bufferObservedOffset("))
    #expect(!persistBody.contains("storeScrollOffset("))
  }

  @Test("Buffered offsets are consumed once")
  @MainActor
  func bufferedOffsetsAreConsumedOnce() {
    let buffer = SettingsScrollPersistenceBuffer()
    buffer.record(128, for: .general)

    #expect(buffer.pendingOffset(for: .general) == 128)
    #expect(buffer.consumeOffset(for: .general) == 128)
    #expect(buffer.consumeOffset(for: .general) == nil)
  }

  @Test("Retry deferrer can cancel pending restore retries")
  @MainActor
  func retryDeferrerCanCancelPendingRestoreRetries() async {
    let deferrer = SettingsScrollRestoreRetryDeferrer()
    var appliedOffsets: [CGFloat] = []

    deferrer.schedule(128) { offset in
      appliedOffsets.append(offset)
    }
    deferrer.cancel()

    for _ in 0..<4 {
      await Task.yield()
    }

    #expect(appliedOffsets.isEmpty)
  }

  @Test("Restore applicator avoids repeated whole-window scroll view searches")
  func restoreApplicatorCachesResolvedScrollView() throws {
    let source = try sourceFile(named: "Views/Settings/SettingsScrollRestoreApplicator.swift")

    #expect(source.contains("private weak var cachedScrollView"))
    #expect(source.contains("private func resolvedScrollView(from view: NSView)"))
    #expect(source.contains("descendantScrollViews(in: contentView)"))
    #expect(!source.contains("settingsDescendantScrollViews"))
  }

  @Test("Restore applicator skips scroll view lookup for top offsets")
  func restoreApplicatorSkipsLookupForTopOffsets() throws {
    let source = try sourceFile(named: "Views/Settings/SettingsScrollRestoreApplicator.swift")
    let applyRange = try #require(source.range(of: "func applyRestore(from view: NSView)"))
    let resolveRange = try #require(source.range(of: "private func resolvedScrollView"))
    let applyBody = String(source[applyRange.lowerBound..<resolveRange.lowerBound])

    #expect(applyBody.contains("guard storedOffset > 0 else"))
    #expect(applyBody.contains("appliedRequest = request"))
  }

  @Test("Restore applicator only schedules changed requests")
  @MainActor
  func restoreApplicatorOnlySchedulesChangedRequests() {
    let coordinator = SettingsScrollRestoreApplicator.Coordinator()
    let firstRequest = SettingsScrollRestoreRequest(id: 1, offset: 240)
    let secondRequest = SettingsScrollRestoreRequest(id: 2, offset: 240)

    #expect(coordinator.updateRequest(firstRequest))
    #expect(!coordinator.updateRequest(firstRequest))
    #expect(coordinator.updateRequest(secondRequest))
    #expect(!coordinator.updateRequest(nil))
  }

  @Test("Restore applicator marks clamped zero targets handled")
  func restoreApplicatorMarksClampedZeroTargetsHandled() throws {
    let source = try sourceFile(named: "Views/Settings/SettingsScrollRestoreApplicator.swift")
    let targetGuardRange = try #require(source.range(of: "guard targetOffset > 0 else"))
    let setOffsetRange = try #require(source.range(of: "SettingsScrollRestoreApplicator.setOffset"))
    let targetGuardBody = String(source[targetGuardRange.lowerBound..<setOffsetRange.lowerBound])

    #expect(targetGuardBody.contains("appliedRequest = request"))
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
      .appendingPathComponent("apps/harness-monitor")
      .appendingPathComponent("Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
