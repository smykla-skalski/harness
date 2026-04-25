import XCTest

@testable import HarnessMonitorE2ECore

final class ResolveCodexLaunchTests: XCTestCase {
  func testPrefersFirstPreferredSlug() throws {
    let json = """
      { "models": [
          { "slug": "gpt-5.5", "supported_reasoning_levels": [{ "effort": "high" }] },
          { "slug": "gpt-5.3-codex-spark", "supported_reasoning_levels": [{ "effort": "low" }, { "effort": "medium" }] },
          { "slug": "gpt-5.4-mini", "supported_reasoning_levels": [{ "effort": "low" }] }
      ] }
      """
    let resolution = CodexLaunchResolver.resolve(fromJSON: Data(json.utf8))
    XCTAssertEqual(resolution, .init(slug: "gpt-5.3-codex-spark", effort: "low"))
  }

  func testFallsBackToAnyModelWhenNoneArePreferred() throws {
    let json = """
      { "models": [
          { "slug": "vendor-only", "supported_reasoning_levels": [{ "effort": "high" }] }
      ] }
      """
    let resolution = CodexLaunchResolver.resolve(fromJSON: Data(json.utf8))
    XCTAssertEqual(resolution, .init(slug: "vendor-only", effort: "high"))
  }

  func testReturnsNilWhenNoModelExposesEffort() throws {
    let json = """
      { "models": [
          { "slug": "gpt-5.5", "supported_reasoning_levels": [] },
          { "slug": "another", "supported_reasoning_levels": [{ "tier": "fast" }] }
      ] }
      """
    XCTAssertNil(CodexLaunchResolver.resolve(fromJSON: Data(json.utf8)))
  }

  func testReturnsNilOnMalformedJSON() throws {
    XCTAssertNil(CodexLaunchResolver.resolve(fromJSON: Data("not json".utf8)))
  }

  func testSkipsPreferredEntryThatLacksEffort() throws {
    let json = """
      { "models": [
          { "slug": "gpt-5.3-codex-spark", "supported_reasoning_levels": [] },
          { "slug": "gpt-5.4-mini", "supported_reasoning_levels": [{ "effort": "low" }] }
      ] }
      """
    let resolution = CodexLaunchResolver.resolve(fromJSON: Data(json.utf8))
    XCTAssertEqual(resolution, .init(slug: "gpt-5.4-mini", effort: "low"))
  }
}
