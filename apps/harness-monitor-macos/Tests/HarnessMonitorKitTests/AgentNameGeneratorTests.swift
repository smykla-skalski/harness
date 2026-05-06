import XCTest

@testable import HarnessMonitorKit

final class AgentNameGeneratorTests: XCTestCase {
  private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return state
    }
  }

  func testCodexNamesStartWithCAndContainX() {
    var rng = SeededRNG(state: 1)
    for _ in 0..<200 {
      let outcome = AgentNameGenerator.generate(for: .codex, using: &rng)
      XCTAssertTrue(
        AgentNameGenerator.validate(outcome.name, runtime: .codex),
        "invalid: \(outcome.name)"
      )
    }
  }

  func testClaudeBothPartsStartWithC() {
    var rng = SeededRNG(state: 2)
    for _ in 0..<200 {
      let outcome = AgentNameGenerator.generate(for: .claude, using: &rng)
      XCTAssertTrue(
        AgentNameGenerator.validate(outcome.name, runtime: .claude),
        "invalid: \(outcome.name)"
      )
    }
  }

  func testGeminiBothPartsStartWithG() {
    var rng = SeededRNG(state: 3)
    for _ in 0..<200 {
      let outcome = AgentNameGenerator.generate(for: .gemini, using: &rng)
      XCTAssertTrue(
        AgentNameGenerator.validate(outcome.name, runtime: .gemini),
        "invalid: \(outcome.name)"
      )
    }
  }

  func testCopilotFirstStartsWithP() {
    var rng = SeededRNG(state: 4)
    for _ in 0..<200 {
      let outcome = AgentNameGenerator.generate(for: .copilot, using: &rng)
      XCTAssertTrue(
        AgentNameGenerator.validate(outcome.name, runtime: .copilot),
        "invalid: \(outcome.name)"
      )
    }
  }

  func testVibeFirstStartsWithV() {
    var rng = SeededRNG(state: 5)
    for _ in 0..<200 {
      let outcome = AgentNameGenerator.generate(for: .vibe, using: &rng)
      XCTAssertTrue(
        AgentNameGenerator.validate(outcome.name, runtime: .vibe),
        "invalid: \(outcome.name)"
      )
    }
  }

  func testOpencodeFirstWithOAndSurnameWithC() {
    var rng = SeededRNG(state: 6)
    for _ in 0..<200 {
      let outcome = AgentNameGenerator.generate(for: .opencode, using: &rng)
      XCTAssertTrue(
        AgentNameGenerator.validate(outcome.name, runtime: .opencode),
        "invalid: \(outcome.name)"
      )
    }
  }

  func testGeneratorAvoidsExcludedFullName() {
    var rng = SeededRNG(state: 7)
    let taken = ["Cassandra Maxwell"]
    for _ in 0..<50 {
      let outcome = AgentNameGenerator.generate(
        for: .codex,
        excluding: taken,
        using: &rng
      )
      XCTAssertNotEqual(outcome.name.lowercased(), "cassandra maxwell")
    }
  }

  func testFirstNameOrSurnameMayRepeatAcrossAgents() {
    var rng = SeededRNG(state: 7)
    let taken = ["Cassandra Maxwell"]
    var sawSharedComponent = false
    for _ in 0..<200 {
      let outcome = AgentNameGenerator.generate(
        for: .codex,
        excluding: taken,
        using: &rng
      )
      let parts = outcome.name.split(separator: " ", maxSplits: 1)
      guard parts.count == 2 else { continue }
      if parts[0].lowercased() == "cassandra" || parts[1].lowercased() == "maxwell" {
        sawSharedComponent = true
        break
      }
    }
    XCTAssertTrue(
      sawSharedComponent,
      "exclusion is full-name only; component reuse must be allowed"
    )
  }

  func testGeneratorAvoidsPreviousValue() {
    var rng = SeededRNG(state: 8)
    let previous = "Calvin Foxworth"
    for _ in 0..<50 {
      let outcome = AgentNameGenerator.generate(
        for: .codex,
        avoiding: previous,
        using: &rng
      )
      XCTAssertNotEqual(outcome.name, previous)
    }
  }

  func testBulkGenerationProducesDiverseNames() {
    var rng = SeededRNG(state: 9)
    var seen = Set<String>()
    for _ in 0..<200 {
      seen.insert(AgentNameGenerator.generate(for: .copilot, using: &rng).name)
    }
    XCTAssertGreaterThan(seen.count, 100, "generator should produce a wide spread")
  }

  func testFallbackAvoidsCollidingNumberedNames() {
    var rng = SeededRNG(state: 11)
    let taken = ["Codex Agent 1", "Codex Agent 2", "Codex Agent 3", "Codex Agent 4"]
    let outcome = AgentNameGenerator.numberedFallback(
      for: .codex,
      taken: AgentNameGenerator.ExclusionSet(taken: taken, previous: nil)
    )
    XCTAssertFalse(taken.contains(outcome))
    XCTAssertTrue(outcome.hasPrefix("Codex Agent"))
  }
}
