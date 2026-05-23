import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("OpenAnything pin store")
@MainActor
struct OpenAnythingPinStoreTests {
  @Test("Pin adds id at the end")
  func pinAppends() async {
    let store = Self.makeStore()
    #expect(store.pin("a"))
    #expect(store.pin("b"))
    #expect(store.recordIDs == ["a", "b"])
  }

  @Test("Pinning twice is a no-op")
  func pinIdempotent() async {
    let store = Self.makeStore()
    store.pin("a")
    #expect(store.pin("a") == false)
    #expect(store.recordIDs == ["a"])
  }

  @Test("Unpin removes the id")
  func unpinRemoves() async {
    let store = Self.makeStore()
    store.pin("a")
    store.pin("b")
    #expect(store.unpin("a"))
    #expect(store.recordIDs == ["b"])
  }

  @Test("Capacity prevents extra pins")
  func capacityPrevents() async {
    let store = Self.makeStore()
    for index in 0..<OpenAnythingPinStore.capacity {
      #expect(store.pin("id-\(index)"))
    }
    #expect(store.pin("over-the-limit") == false)
    #expect(store.recordIDs.count == OpenAnythingPinStore.capacity)
  }

  @Test("Move reorders within bounds")
  func moveReorders() async {
    let store = Self.makeStore()
    store.pin("a")
    store.pin("b")
    store.pin("c")
    #expect(store.move("c", to: 0))
    #expect(store.recordIDs == ["c", "a", "b"])
  }

  @Test("Persistence round-trips")
  func persistenceRoundTrips() async {
    let defaults = Self.ephemeralDefaults()
    let first = OpenAnythingPinStore(defaults: defaults, key: "test")
    first.pin("a")
    first.pin("b")

    let second = OpenAnythingPinStore(defaults: defaults, key: "test")
    #expect(second.recordIDs == ["a", "b"])
  }

  private static func makeStore() -> OpenAnythingPinStore {
    OpenAnythingPinStore(defaults: ephemeralDefaults(), key: "test")
  }

  private static func ephemeralDefaults() -> UserDefaults {
    UserDefaults(suiteName: "OpenAnythingPinStoreTests-\(UUID().uuidString)")
      ?? UserDefaults.standard
  }
}
