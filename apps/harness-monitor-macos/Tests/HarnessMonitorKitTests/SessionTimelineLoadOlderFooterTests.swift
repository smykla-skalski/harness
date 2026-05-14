import AppKit
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Session timeline load-older footer")
struct SessionTimelineLoadOlderFooterTests {
  @Test("Footer invokes the load-older callback when it appears")
  func footerInvokesCallbackOnAppear() async throws {
    let probe = LoadOlderCallbackProbe()
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 320, height: 80),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    defer { window.close() }

    let host = NSHostingView(
      rootView: SessionTimelineLoadOlderFooter(
        isLoading: false,
        onAppear: { probe.markFired() }
      )
    )
    host.frame = CGRect(x: 0, y: 0, width: 320, height: 80)
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    host.layoutSubtreeIfNeeded()

    try await waitFor(timeout: 1.0) { probe.fireCount > 0 }

    #expect(probe.fireCount >= 1)
  }

  @Test("Footer accepts both loading and idle isLoading states")
  func footerAcceptsBothLoadingStates() {
    let idleHost = NSHostingView(
      rootView: SessionTimelineLoadOlderFooter(isLoading: false, onAppear: nil)
    )
    let loadingHost = NSHostingView(
      rootView: SessionTimelineLoadOlderFooter(isLoading: true, onAppear: nil)
    )
    idleHost.frame = CGRect(x: 0, y: 0, width: 320, height: 60)
    loadingHost.frame = CGRect(x: 0, y: 0, width: 320, height: 60)
    idleHost.layoutSubtreeIfNeeded()
    loadingHost.layoutSubtreeIfNeeded()

    #expect(idleHost.fittingSize.height > 0)
    #expect(loadingHost.fittingSize.height > 0)
  }

  @Test("LazyVStack renders the footer when hasOlder is true")
  func sessionTimelineListIncludesFooterWhenHasOlder() throws {
    let sourceFile = try timelineSource(named: "MonitorTimelineSection.swift")

    #expect(sourceFile.contains("if presentation.navigation.hasOlder {"))
    #expect(sourceFile.contains("SessionTimelineLoadOlderFooter("))
    #expect(sourceFile.contains("onRequestLoadOlder: requestLoadOlderTimelineChunk"))
  }

  @Test("Load-older trigger is routed to the store's older-chunk appender")
  func loadOlderTriggerRoutesToStoreAppender() throws {
    let sourceFile = try timelineSource(named: "MonitorTimelineSection.swift")

    #expect(sourceFile.contains("static let loadOlderChunkSize = 200"))
    #expect(
      sourceFile.contains("await store.appendSelectedTimelineOlderChunk(")
    )
    #expect(sourceFile.contains("retainedLimit: nil"))
  }

  @Test("Footer is published with the load-older accessibility identifier")
  func footerPublishesAccessibilityIdentifier() throws {
    let sourceFile = try timelineSource(named: "MonitorTimelineSection.swift")

    #expect(
      sourceFile.contains(
        "HarnessMonitorAccessibility.sessionTimelineLoadOlderFooter"
      )
    )
  }

  private func timelineSource(named fileName: String) throws -> String {
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
        "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/Timeline"
      )
      .appendingPathComponent(fileName)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }

  private func waitFor(
    timeout: TimeInterval,
    condition: @escaping () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
  }
}

@MainActor
private final class LoadOlderCallbackProbe {
  private(set) var fireCount = 0

  func markFired() {
    fireCount += 1
  }
}
