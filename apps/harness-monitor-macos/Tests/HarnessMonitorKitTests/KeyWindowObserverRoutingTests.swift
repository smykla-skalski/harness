import Testing

@testable import HarnessMonitorKit

@MainActor
struct KeyWindowObserverRoutingTests {
  @Test("token-based window matching avoids substring collisions")
  func matchesWindowIDByToken() {
    #expect(KeyWindowObserver.matchesWindowID("decisions", expected: "decisions"))
    #expect(
      KeyWindowObserver.matchesWindowID("com.apple.SwiftUI.window.decisions", expected: "decisions")
    )
    #expect(!KeyWindowObserver.matchesWindowID("decisionsPanel", expected: "decisions"))
    #expect(!KeyWindowObserver.matchesWindowID("mainframe", expected: "main"))
  }
}
