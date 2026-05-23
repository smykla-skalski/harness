import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("OpenAnything palette model")
@MainActor
struct OpenAnythingPaletteModelTests {
  @Test("Present resets state and marks the model open")
  func presentResetsState() async {
    let model = Self.makeModel()
    model.present(targetWindowID: "win-1")

    #expect(model.isPresented)
    #expect(model.targetWindowID == "win-1")
    #expect(model.query.isEmpty)
    #expect(model.lastDismissReason == nil)
  }

  @Test("Dismiss is idempotent when not presented")
  func dismissIdempotent() async {
    let model = Self.makeModel()
    model.dismiss()
    #expect(model.isPresented == false)
    #expect(model.lastDismissReason == nil)
  }

  @Test("Dismiss records the reason")
  func dismissRecordsReason() async {
    let model = Self.makeModel()
    model.present(targetWindowID: nil)
    model.dismiss(reason: .windowResignedKey)

    #expect(model.isPresented == false)
    #expect(model.lastDismissReason == .windowResignedKey)
  }

  @Test("Empty query runSearch is a no-op actor hop")
  func emptyQueryRunSearchSkipsActor() async {
    let model = Self.makeModel()
    await model.replaceCorpus(Self.sampleRecords)
    model.present(targetWindowID: nil)
    model.query = "   "

    await model.runSearch()

    // The run did not populate `results`; displayedResults should still
    // surface the suggested-lane bundle.
    #expect(model.results == .empty)
  }

  @Test("recordExecution promotes the record in recency")
  func executionPromotes() async {
    let model = Self.makeModel()
    model.recordExecution(of: "session.alpha")
    #expect(model.recency.entries.first?.recordID == "session.alpha")
    #expect(model.lastDismissReason == .hitExecuted(recordID: "session.alpha"))
  }

  @Test("togglePin flips state and reports the result")
  func togglePinFlips() async {
    let model = Self.makeModel()
    let onAfterFirst = model.togglePin("a")
    let onAfterSecond = model.togglePin("a")

    #expect(onAfterFirst == true)
    #expect(onAfterSecond == false)
    #expect(model.pins.recordIDs.isEmpty)
  }

  @Test("Pinned IDs surface at the top of the empty-query lane")
  func pinnedIDsSurfaceFirst() async {
    let model = Self.makeModel()
    model.togglePin("action.refresh")

    await model.replaceCorpus(Self.sampleRecords)

    let topHit = model.suggestedResults.allHits.first
    #expect(topHit?.id == "action.refresh")
  }

  @Test("Selection survives a corpus refresh when the record remains")
  func stickySelectionAcrossCorpus() async {
    let model = Self.makeModel()
    await model.replaceCorpus(Self.sampleRecords)
    model.present(targetWindowID: nil)
    model.query = "alp"
    await model.runSearch()
    let initialSelection = model.selectedHitID
    #expect(initialSelection != nil)

    await model.replaceCorpus(Self.sampleRecords)
    #expect(model.selectedHitID == initialSelection)
  }

  private static func makeModel() -> OpenAnythingPaletteModel {
    let defaults =
      UserDefaults(suiteName: "OpenAnythingPaletteModelTests-\(UUID().uuidString)")
      ?? UserDefaults.standard
    return OpenAnythingPaletteModel(
      recency: OpenAnythingRecencyStore(defaults: defaults, key: "recency"),
      pins: OpenAnythingPinStore(defaults: defaults, key: "pins")
    )
  }

  private static let sampleRecords: [OpenAnythingRecord] = [
    OpenAnythingRecord(
      id: "action.refresh",
      domain: .actions,
      target: .action(.refresh),
      title: "Refresh",
      isSuggested: true
    ),
    OpenAnythingRecord(
      id: "session.alpha",
      domain: .sessions,
      target: .session(sessionID: "alpha"),
      title: "Alpha Session"
    ),
    OpenAnythingRecord(
      id: "session.beta",
      domain: .sessions,
      target: .session(sessionID: "beta"),
      title: "Beta Session"
    ),
  ]
}
