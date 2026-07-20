import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
struct ConnectionChromeAvailabilityGateTests {
  @Test("A reconnect that finishes inside the grace period never shows the chrome banner")
  func reconnectInsideGracePeriodNeverShowsBanner() async throws {
    let store = await makeBootstrappedStore()
    store.chromeDataAvailabilityGracePeriod = .seconds(60)

    store.connectionState = .offline("socket closed")
    #expect(store.contentUI.chrome.sessionDataAvailability == .live)

    store.connectionState = .connecting
    #expect(store.contentUI.chrome.sessionDataAvailability == .live)

    store.connectionState = .online
    #expect(store.contentUI.chrome.sessionDataAvailability == .live)
  }

  @Test("The gate delays presentation without hiding the truthful store availability")
  func gateKeepsStoreAvailabilityTruthful() async throws {
    let store = await makeBootstrappedStore()
    store.chromeDataAvailabilityGracePeriod = .seconds(60)

    store.connectionState = .offline("daemon stopped")

    #expect(store.sessionDataAvailability != .live)
    #expect(store.contentUI.chrome.sessionDataAvailability == .live)
  }

  @Test("An outage that outlasts the grace period reaches the chrome banner")
  func outageBeyondGracePeriodShowsBanner() async throws {
    let store = await makeBootstrappedStore()
    store.chromeDataAvailabilityGracePeriod = .zero

    store.connectionState = .offline("daemon stopped")

    #expect(store.contentUI.chrome.sessionDataAvailability == store.sessionDataAvailability)
    #expect(store.contentUI.chrome.sessionDataAvailability != .live)
  }

  @Test("A presented banner survives the connecting leg of a retry instead of blinking")
  func presentedBannerSurvivesConnectingRetries() async throws {
    let store = await makeBootstrappedStore()
    store.chromeDataAvailabilityGracePeriod = .zero

    store.connectionState = .offline("daemon stopped")
    let presented = store.contentUI.chrome.sessionDataAvailability
    #expect(presented != .live)

    store.connectionState = .connecting
    #expect(store.contentUI.chrome.sessionDataAvailability == presented)

    store.connectionState = .offline("daemon stopped")
    #expect(store.contentUI.chrome.sessionDataAvailability == presented)
  }

  @Test("Reaching online clears the presented banner immediately")
  func onlineClearsPresentedBannerImmediately() async throws {
    let store = await makeBootstrappedStore()
    store.chromeDataAvailabilityGracePeriod = .zero

    store.connectionState = .offline("daemon stopped")
    #expect(store.contentUI.chrome.sessionDataAvailability != .live)

    store.connectionState = .online
    #expect(store.contentUI.chrome.sessionDataAvailability == .live)
  }

  @Test("Connecting before any known outage keeps the chrome banner hidden")
  func connectingWithoutKnownOutageKeepsBannerHidden() async throws {
    let store = await makeBootstrappedStore()
    store.chromeDataAvailabilityGracePeriod = .zero

    store.connectionState = .connecting

    #expect(store.contentUI.chrome.sessionDataAvailability == .live)
  }

  @Test("A sustained outage presents the banner without any further state change")
  func sustainedOutagePresentsBannerOnItsOwn() async throws {
    let store = await makeBootstrappedStore()
    store.chromeDataAvailabilityGracePeriod = .milliseconds(50)

    store.connectionState = .offline("daemon stopped")
    #expect(store.contentUI.chrome.sessionDataAvailability == .live)

    try await Task.sleep(for: .milliseconds(400))

    #expect(store.contentUI.chrome.sessionDataAvailability != .live)
  }

  @Test("A seeded preview store shows its offline chrome without waiting")
  func seededPreviewStoreShowsOfflineChromeImmediately() async throws {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .offlineCached)

    #expect(store.contentUI.chrome.sessionDataAvailability == store.sessionDataAvailability)
    #expect(store.contentUI.chrome.sessionDataAvailability != .live)
  }

  @Test("A stale-data blip while online never reaches the chrome banner")
  func staleDataBlipWhileOnlineNeverShowsBanner() async throws {
    let store = await makeBootstrappedStore()
    store.chromeDataAvailabilityGracePeriod = .seconds(60)

    store.isShowingCachedSelectedSession = true
    #expect(store.contentUI.chrome.sessionDataAvailability == .live)

    store.isShowingCachedSelectedSession = false
    #expect(store.contentUI.chrome.sessionDataAvailability == .live)
  }
}
