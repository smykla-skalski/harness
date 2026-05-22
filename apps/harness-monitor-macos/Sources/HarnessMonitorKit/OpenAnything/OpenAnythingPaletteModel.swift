import Foundation
import Observation

@MainActor
@Observable
public final class OpenAnythingPaletteModel {
  public var query = "" {
    didSet {
      guard oldValue != query else { return }
      selectedHitID = nil
    }
  }

  public private(set) var isPresented = false
  public private(set) var targetWindowID: String?
  public private(set) var results = OpenAnythingResults.empty
  public private(set) var selectedHitID: String?

  @ObservationIgnored private let index: OpenAnythingIndex

  public init(index: OpenAnythingIndex = OpenAnythingIndex()) {
    self.index = index
  }

  public var selectedHit: OpenAnythingHit? {
    let hits = results.allHits
    guard !hits.isEmpty else { return nil }
    if let selectedHitID, let selected = hits.first(where: { $0.id == selectedHitID }) {
      return selected
    }
    return hits.first
  }

  public func present(targetWindowID: String?) {
    self.targetWindowID = targetWindowID
    query = ""
    results = .empty
    selectedHitID = nil
    isPresented = true
  }

  public func dismiss() {
    guard isPresented || !query.isEmpty || !results.isEmpty else {
      return
    }
    query = ""
    results = .empty
    selectedHitID = nil
    targetWindowID = nil
    isPresented = false
  }

  public func isPresented(in windowID: String, isKeyWindow: Bool) -> Bool {
    guard isPresented else { return false }
    guard let targetWindowID else { return isKeyWindow }
    return targetWindowID == windowID
  }

  public func replaceCorpus(_ records: [OpenAnythingRecord]) async {
    await index.replace(records: records)
    guard isPresented, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return
    }
    await runSearch()
  }

  public func runSearch() async {
    let results = await index.search(query: query)
    guard !Task.isCancelled else { return }
    self.results = results
    normalizeSelection()
  }

  public func moveSelection(by delta: Int) {
    let hits = results.allHits
    guard !hits.isEmpty else {
      selectedHitID = nil
      return
    }
    let currentIndex =
      selectedHitID.flatMap { selectedID in
        hits.firstIndex { $0.id == selectedID }
      } ?? 0
    let nextIndex = min(max(currentIndex + delta, 0), hits.count - 1)
    selectedHitID = hits[nextIndex].id
  }

  public func selectFirstHitIfNeeded() {
    normalizeSelection()
  }

  private func normalizeSelection() {
    let hits = results.allHits
    guard !hits.isEmpty else {
      selectedHitID = nil
      return
    }
    if let selectedHitID, hits.contains(where: { $0.id == selectedHitID }) {
      return
    }
    selectedHitID = hits.first?.id
  }
}
