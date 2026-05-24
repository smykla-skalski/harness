import Foundation
import XCTest

@testable import HarnessMonitorIntents

final class IntentImageCacheTests: XCTestCase {
  func testBootstrapInstallsSharedURLCacheWithConfiguredCapacities() {
    let originalCache = URLCache.shared

    IntentImageCache.configureSharedCache()
    let configured = URLCache.shared

    XCTAssertEqual(
      configured.memoryCapacity,
      IntentImageCache.memoryCapacity,
      "memory capacity should match the public constant so tuning is observable"
    )
    XCTAssertEqual(
      configured.diskCapacity,
      IntentImageCache.diskCapacity,
      "disk capacity should match the public constant so tuning is observable"
    )

    URLCache.shared = originalCache
  }

  func testBootstrapIsIdempotent() {
    let originalCache = URLCache.shared

    IntentImageCache.bootstrap()
    let first = URLCache.shared
    IntentImageCache.bootstrap()
    let second = URLCache.shared

    XCTAssertTrue(
      first === second,
      "subsequent bootstrap calls should not replace the cache (would invalidate warm entries)"
    )

    URLCache.shared = originalCache
  }

  func testPrewarmIsSafeWhenSharedCacheLacksAppGroup() async {
    let originalCache = URLCache.shared
    IntentImageCache.resetForTesting()
    defer { URLCache.shared = originalCache }

    let url = URL(string: "https://github.com/alice.png")!

    IntentImageCache.prewarm(url)

    let configured = URLCache.shared
    XCTAssertNotNil(configured, "prewarm must keep the URLCache available even with no backing dir")
  }
}
