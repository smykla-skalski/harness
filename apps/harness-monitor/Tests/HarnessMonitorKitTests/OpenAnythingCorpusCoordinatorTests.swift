import Testing

@testable import HarnessMonitorKit

/// Audit #55: integration coverage for the coordinator + palette wiring.
/// The coordinator owns the dedupe-by-signature contract; without these
/// tests a future refactor could re-introduce the per-window-N rebuild
/// regression the coordinator was created to kill.
@Suite("OpenAnythingCorpusCoordinator")
@MainActor
struct OpenAnythingCorpusCoordinatorTests {
  private func makeRecord(id: String, title: String) -> OpenAnythingRecord {
    OpenAnythingRecord(
      id: id,
      domain: .actions,
      target: .action(.refresh),
      title: title
    )
  }

  @Test("Accepting a new corpus rebuilds the palette index")
  func acceptsCorpus() async {
    let coordinator = OpenAnythingCorpusCoordinator()
    let records = [makeRecord(id: "a", title: "Alpha")]
    let signature = OpenAnythingCorpusSignature.compute(records)
    await coordinator.acceptCorpus(records, signature: signature)
    #expect(coordinator.lastSignature == signature)
    #expect(coordinator.palette.recordCount == 1)
  }

  @Test("Re-accepting the same signature is a no-op")
  func dedupesBySignature() async {
    let coordinator = OpenAnythingCorpusCoordinator()
    let records = [makeRecord(id: "a", title: "Alpha")]
    let signature = OpenAnythingCorpusSignature.compute(records)
    await coordinator.acceptCorpus(records, signature: signature)
    #expect(coordinator.palette.recordCount == 1)
    let before = coordinator.lastSignature
    await coordinator.acceptCorpus(records, signature: signature)
    #expect(coordinator.lastSignature == before)
    #expect(coordinator.palette.recordCount == 1)
  }

  @Test("Different signature triggers a fresh rebuild")
  func newSignatureRebuilds() async {
    let coordinator = OpenAnythingCorpusCoordinator()
    let first = [makeRecord(id: "a", title: "Alpha")]
    let firstSig = OpenAnythingCorpusSignature.compute(first)
    await coordinator.acceptCorpus(first, signature: firstSig)
    let second = [
      makeRecord(id: "a", title: "Alpha"),
      makeRecord(id: "b", title: "Beta"),
    ]
    let secondSig = OpenAnythingCorpusSignature.compute(second)
    await coordinator.acceptCorpus(second, signature: secondSig)
    #expect(coordinator.lastSignature == secondSig)
    #expect(coordinator.palette.recordCount == 2)
  }
}
