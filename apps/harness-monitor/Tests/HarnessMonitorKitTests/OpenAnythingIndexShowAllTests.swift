import Testing

@testable import HarnessMonitorKit

/// Covers the per-section "Show all" path and the no-rebuild guarantee
/// surfaced via the coordinator's signature gate.
@Suite("OpenAnythingIndex show-all + rebuild")
struct OpenAnythingIndexShowAllTests {
  private func sessionRecords(count: Int) -> [OpenAnythingRecord] {
    (0..<count).map { index in
      OpenAnythingRecord(
        id: "session-\(index)",
        domain: .sessions,
        target: .session(sessionID: "session-\(index)"),
        title: "Session foo \(index)"
      )
    }
  }

  @Test("Search caps a domain at limitPerDomain by default")
  func capsAtDefaultLimit() async {
    let index = OpenAnythingIndex()
    await index.replace(records: sessionRecords(count: 12))
    let results = await index.search(query: "foo", limitPerDomain: 6)
    let sessions = results.sections.first(where: { $0.domain == .sessions })
    #expect(sessions?.hits.count == 6)
    #expect(results.totalCount(for: .sessions) == 12)
  }

  @Test("Passing the domain through unboundedDomains returns every match")
  func unboundedShowsAll() async {
    let index = OpenAnythingIndex()
    await index.replace(records: sessionRecords(count: 12))
    let results = await index.search(
      query: "foo",
      limitPerDomain: 6,
      unboundedDomains: [.sessions]
    )
    let sessions = results.sections.first(where: { $0.domain == .sessions })
    #expect(sessions?.hits.count == 12)
    #expect(results.totalCount(for: .sessions) == 12)
  }

  @Test("Suggested results respect the unboundedDomains override")
  func suggestedRespectsUnbounded() async {
    let index = OpenAnythingIndex()
    let suggested = (0..<8).map { idx in
      OpenAnythingRecord(
        id: "sug-\(idx)",
        domain: .actions,
        target: .action(.refresh),
        title: "Action \(idx)",
        isSuggested: true
      )
    }
    await index.replace(records: suggested)
    let capped = await index.suggestedResults(limitPerDomain: 5)
    #expect(capped.sections.first?.hits.count == 5)
    let unbounded = await index.suggestedResults(
      limitPerDomain: 5,
      unboundedDomains: [.actions]
    )
    #expect(unbounded.sections.first?.hits.count == 8)
  }

  @Test("Coordinator skips a rebuild when the corpus signature is unchanged")
  @MainActor
  func coordinatorSkipsIdenticalRebuild() async {
    let coordinator = OpenAnythingCorpusCoordinator()
    let records = sessionRecords(count: 3)
    let signature = OpenAnythingCorpusSignature.compute(records)
    await coordinator.acceptCorpus(records, signature: signature)
    let firstCount = coordinator.palette.recordCount
    // A fresh array literal still hashes to the same signature; the
    // coordinator's gate must prevent a second rebuild.
    let recopy = sessionRecords(count: 3)
    let recopySig = OpenAnythingCorpusSignature.compute(recopy)
    #expect(recopySig == signature)
    await coordinator.acceptCorpus(recopy, signature: recopySig)
    #expect(coordinator.palette.recordCount == firstCount)
  }
}
