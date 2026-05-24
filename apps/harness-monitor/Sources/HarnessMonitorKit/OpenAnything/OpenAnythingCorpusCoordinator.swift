import Foundation
import Observation

/// Single owner of the Open Anything corpus rebuild lifecycle.
///
/// Before this coordinator existed, every window's host modifier carried its
/// own `.task(id: corpusSignature)` that walked the store and called
/// `palette.replaceCorpus`. With N session windows open, every store update
/// triggered ~N redundant hash walks (200-entry timeline included) and
/// ~N redundant index rebuilds. The coordinator centralises the rebuild and
/// dedupes on a deterministic content signature; per-window host modifiers
/// become pure overlay logic.
@MainActor
@Observable
public final class OpenAnythingCorpusCoordinator {
  public let palette: OpenAnythingPaletteModel
  public private(set) var lastSignature: Int?

  public init(palette: OpenAnythingPaletteModel = OpenAnythingPaletteModel()) {
    self.palette = palette
  }

  /// Replace the corpus iff the signature differs from the last accepted one.
  /// Callers should pre-compute the signature alongside the records so the
  /// dedupe check is O(1) here.
  public func acceptCorpus(_ records: [OpenAnythingRecord], signature: Int) async {
    guard !Task.isCancelled, lastSignature != signature else { return }
    lastSignature = signature
    await palette.replaceCorpus(records)
  }
}
