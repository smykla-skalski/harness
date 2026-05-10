import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("AppSearchModel cancellation and apply contract")
@MainActor
struct AppSearchModelDebounceTests {

  @Test("Empty query resets results without crossing the actor boundary")
  func emptyQueryShortCircuits() async {
    let probe = ProviderProbe()
    let model = AppSearchModel(searchProvider: { query, _ in
      await probe.record(query: query)
      return Self.fixture(query: query)
    })
    await model.runSearch(query: "", primary: nil)
    #expect(await probe.callCount == 0)
    #expect(model.query.isEmpty)
    #expect(model.results.isEmpty)
    #expect(model.isSearching == false)
  }

  @Test("Whitespace-only query is treated as empty")
  func whitespaceOnlyQueryIsEmpty() async {
    let probe = ProviderProbe()
    let model = AppSearchModel(searchProvider: { query, _ in
      await probe.record(query: query)
      return Self.fixture(query: query)
    })
    await model.runSearch(query: "   \n\t  ", primary: nil)
    #expect(await probe.callCount == 0)
    #expect(model.results.isEmpty)
  }

  @Test("Non-empty query trims whitespace and applies results")
  func nonEmptyQueryAppliesResults() async {
    let model = AppSearchModel(searchProvider: { trimmed, _ in
      Self.fixture(query: trimmed)
    })
    await model.runSearch(query: "  alpha  ", primary: .agents)
    #expect(model.query == "alpha")
    #expect(model.results.query == "alpha")
    #expect(model.isSearching == false)
  }

  @Test("Cancelled task does not overwrite earlier results")
  func cancelledTaskDoesNotOverwrite() async {
    let gate = SignalGate()
    let model = AppSearchModel(searchProvider: { query, _ in
      await gate.wait()
      return Self.fixture(query: query)
    })

    // Seed a known prior result. Pre-signal so the seed call doesn't block.
    await gate.signal()
    await model.runSearch(query: "seed", primary: nil)
    #expect(model.query == "seed")

    // Start a search that will be cancelled while suspended on the gate.
    let cancellable = Task { @MainActor in
      await model.runSearch(query: "later", primary: nil)
    }
    // Yield so `cancellable` reaches the gate's await before we cancel it.
    await Task.yield()
    cancellable.cancel()
    // Release the provider so the cancelled task can complete its body and
    // hit the `Task.isCancelled` guard inside `runSearch`.
    await gate.signal()
    _ = await cancellable.value

    #expect(model.query == "seed")
    #expect(model.isSearching == false)
  }

  @Test("clear() resets state")
  func clearResetsState() async {
    let model = AppSearchModel(searchProvider: { query, _ in
      Self.fixture(query: query)
    })
    await model.runSearch(query: "alpha", primary: nil)
    #expect(model.query == "alpha")
    model.clear()
    #expect(model.query.isEmpty)
    #expect(model.results.isEmpty)
    #expect(model.isSearching == false)
  }

  @Test("Provider receives the trimmed query and primary domain")
  func providerReceivesTrimmedInputs() async {
    let probe = ProviderProbe()
    let model = AppSearchModel(searchProvider: { query, primary in
      await probe.record(query: query, primary: primary)
      return Self.fixture(query: query)
    })
    await model.runSearch(query: "  beta  ", primary: .decisions)
    #expect(await probe.lastQuery == "beta")
    #expect(await probe.lastPrimary == .decisions)
  }

  // MARK: Fixture

  private static func fixture(query: String) -> AppSearchResults {
    AppSearchResults(
      query: query,
      primaryDomain: nil,
      sections: [
        AppSearchSection(
          domain: .agents,
          hits: [
            AppSearchHit(
              domain: .agents,
              id: "a1",
              title: query,
              subtitle: nil,
              systemImage: AppSearchDomain.agents.systemImage,
              score: 0
            )
          ],
          truncated: false
        )
      ]
    )
  }
}

/// Counting async semaphore. Signals queue when no waiter is present so
/// tests don't have to interleave wait/signal in lock-step.
private actor SignalGate {
  private var pendingSignals = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if pendingSignals > 0 {
      pendingSignals -= 1
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func signal() {
    if waiters.isEmpty {
      pendingSignals += 1
      return
    }
    let next = waiters.removeFirst()
    next.resume()
  }
}

/// Records the queries a provider closure was called with. Backed by an
/// actor so concurrent calls don't race on the counters.
private actor ProviderProbe {
  private(set) var callCount = 0
  private(set) var lastQuery: String?
  private(set) var lastPrimary: AppSearchDomain?

  func record(query: String, primary: AppSearchDomain? = nil) {
    callCount += 1
    lastQuery = query
    lastPrimary = primary
  }
}
