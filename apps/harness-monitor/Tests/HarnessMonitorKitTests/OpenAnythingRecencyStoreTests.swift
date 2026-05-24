import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("OpenAnything recency store")
@MainActor
struct OpenAnythingRecencyStoreTests {
  @Test("Recording promotes a record and counts uses")
  func recordingPromotesAndCounts() async {
    let defaults = Self.ephemeralDefaults()
    let store = OpenAnythingRecencyStore(defaults: defaults, key: "test")

    store.record("a")
    store.record("a")
    store.record("b")

    #expect(store.entries.first?.recordID == "b")
    #expect(store.entries.count == 2)
    #expect(store.entries.first(where: { $0.recordID == "a" })?.useCount == 2)
  }

  @Test("Capacity trims oldest entries")
  func capacityTrimsOldest() async {
    let defaults = Self.ephemeralDefaults()
    let store = OpenAnythingRecencyStore(defaults: defaults, key: "test")

    for index in 0..<(OpenAnythingRecencyStore.capacity + 5) {
      store.record("id-\(index)")
    }

    #expect(store.entries.count == OpenAnythingRecencyStore.capacity)
    #expect(store.entries.first?.recordID == "id-\(OpenAnythingRecencyStore.capacity + 4)")
    #expect(store.entries.last?.recordID == "id-5")
  }

  @Test("Score decays toward zero with age")
  func scoreDecaysWithAge() async {
    let defaults = Self.ephemeralDefaults()
    let store = OpenAnythingRecencyStore(defaults: defaults, key: "test")

    let now = Date()
    let stamp = now.addingTimeInterval(-30 * 86_400)
    store.record("a", at: stamp)

    let halfLifeScore = store.score(for: "a", now: now)

    #expect(halfLifeScore > 0)
    #expect(halfLifeScore < 1.0)  // useCount 1 * 2^-1 = 0.5
    #expect(abs(halfLifeScore - 0.5) < 0.0001)
  }

  @Test("Persistence round-trips across instances")
  func persistenceRoundTrips() async {
    let defaults = Self.ephemeralDefaults()
    let first = OpenAnythingRecencyStore(defaults: defaults, key: "test")
    first.record("a")
    first.record("b")

    let second = OpenAnythingRecencyStore(defaults: defaults, key: "test")

    #expect(second.entries.map(\.recordID) == ["b", "a"])
  }

  @Test("Clear empties entries")
  func clearEmpties() async {
    let defaults = Self.ephemeralDefaults()
    let store = OpenAnythingRecencyStore(defaults: defaults, key: "test")
    store.record("a")
    store.clear()
    #expect(store.entries.isEmpty)
  }

  private static func ephemeralDefaults() -> UserDefaults {
    let suiteName = "OpenAnythingRecencyStoreTests-\(UUID().uuidString)"
    guard let suite = UserDefaults(suiteName: suiteName) else {
      preconditionFailure("Failed to create OpenAnythingRecencyStore test defaults")
    }
    suite.removePersistentDomain(forName: suiteName)
    return suite
  }
}
