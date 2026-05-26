import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Harness Monitor trackpad history")
struct HarnessMonitorTrackpadHistoryTests {
  @Test("Trackpad history defaults to enabled")
  func defaultsToEnabled() {
    let suiteName = "HarnessMonitorTrackpadHistoryTests.defaults"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      Issue.record("Failed to create UserDefaults suite")
      return
    }
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(HarnessMonitorTrackpadNavigationDefaults.read(userDefaults: defaults))
  }

  @Test("Trackpad history reads the stored override")
  func readsStoredOverride() {
    let suiteName = "HarnessMonitorTrackpadHistoryTests.override"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      Issue.record("Failed to create UserDefaults suite")
      return
    }
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set(false, forKey: HarnessMonitorTrackpadNavigationDefaults.enabledKey)

    #expect(!HarnessMonitorTrackpadNavigationDefaults.read(userDefaults: defaults))
  }

  @Test("Positive gesture amount resolves to back when back navigation is available")
  func resolvesBackDirection() {
    #expect(
      HarnessTrackpadHistoryDirection.resolve(
        gestureAmount: 0.4,
        canGoBack: true,
        canGoForward: true
      ) == .back
    )
  }

  @Test("Negative gesture amount resolves to forward when forward navigation is available")
  func resolvesForwardDirection() {
    #expect(
      HarnessTrackpadHistoryDirection.resolve(
        gestureAmount: -0.4,
        canGoBack: true,
        canGoForward: true
      ) == .forward
    )
  }

  @Test("Gesture amounts below the threshold do not commit navigation")
  func belowThresholdDoesNotCommit() {
    #expect(
      HarnessTrackpadHistoryDirection.resolve(
        gestureAmount: 0.2,
        canGoBack: true,
        canGoForward: true
      ) == nil
    )
    #expect(
      HarnessTrackpadHistoryDirection.resolve(
        gestureAmount: -0.2,
        canGoBack: true,
        canGoForward: true
      ) == nil
    )
  }

  @Test("Dashboard route support excludes horizontally interactive routes")
  func dashboardRouteSupport() {
    #expect(DashboardWindowRoute.taskBoard.supportsTrackpadHistorySwipe)
    #expect(DashboardWindowRoute.notifications.supportsTrackpadHistorySwipe)
    #expect(DashboardWindowRoute.diagnostics.supportsTrackpadHistorySwipe)
    #expect(!DashboardWindowRoute.policyCanvas.supportsTrackpadHistorySwipe)
    #expect(!DashboardWindowRoute.debugging.supportsTrackpadHistorySwipe)
    #expect(!DashboardWindowRoute.reviews.supportsTrackpadHistorySwipe)
  }

  @Test("Session route support excludes the policy canvas")
  func sessionRouteSupport() {
    #expect(SessionWindowRoute.overview.supportsTrackpadHistorySwipe)
    #expect(SessionWindowRoute.agents.supportsTrackpadHistorySwipe)
    #expect(SessionWindowRoute.tasks.supportsTrackpadHistorySwipe)
    #expect(SessionWindowRoute.decisions.supportsTrackpadHistorySwipe)
    #expect(SessionWindowRoute.timeline.supportsTrackpadHistorySwipe)
    #expect(!SessionWindowRoute.policyCanvas.supportsTrackpadHistorySwipe)
  }
}
