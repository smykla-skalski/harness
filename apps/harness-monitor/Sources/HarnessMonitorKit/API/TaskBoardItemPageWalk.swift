import Foundation

/// Stop after this many pages. A daemon that kept handing back a cursor
/// without ever draining would otherwise spin the walk below forever.
private let taskBoardItemPageLimit = 200

/// One transport's bounded task-board page read.
///
/// The daemon caps every list response, so each transport exposes a single
/// page and they share the walk below instead of folding pages their own way.
protocol TaskBoardItemPageSource: Sendable {
  func taskBoardItemPage(
    status: TaskBoardStatus?,
    cursor: String?
  ) async throws -> TaskBoardListItemsResponseWire
}

extension TaskBoardItemPageSource {
  /// Read the whole selection by walking from the first page.
  ///
  /// The merged response keeps the *first* page's `itemsChangeSeq` on purpose.
  /// It is the oldest observation of the board, so a board that changed under
  /// the walk fails the next position CAS instead of letting it apply against
  /// a sequence that never described the items beside it.
  ///
  /// A walk that cannot drain the selection throws rather than answering with
  /// what it has. Every caller folds this into a whole-board value - one of
  /// them into `TaskBoardListItemsSnapshot`, which has nowhere to record that
  /// the read stopped early - so a partial result would be indistinguishable
  /// from a complete one at every call site.
  ///
  /// Ids are tracked because a repeat does not only come from a cursor that
  /// stalls. A cursor whose anchor left the selection between two reads resumes
  /// at the slot that anchor held, so a page can re-serve a row an earlier page
  /// returned while still advancing to a *different* cursor - the stall check
  /// below never sees it. These items reach `ForEach(..., id: \.id)`, which
  /// breaks on a duplicate identity, so the walk drops the repeat.
  func mergedTaskBoardItemPages(
    status: TaskBoardStatus?
  ) async throws -> TaskBoardListItemsResponseWire {
    var merged = try await taskBoardItemPage(status: status, cursor: nil)
    var seen = Set<String>()
    merged.items = merged.items.filter { seen.insert($0.id).inserted }
    var cursor = merged.nextCursor
    var pages = 1
    while let next = cursor {
      // A board this long is past what one refresh can hold, and the daemon
      // never pairs a cursor with an empty page or repeats the resume point it
      // was handed, so each of these means the read cannot be completed.
      guard pages < taskBoardItemPageLimit else {
        throw HarnessMonitorAPIError.invalidResponse
      }
      let page = try await taskBoardItemPage(status: status, cursor: next)
      guard !page.items.isEmpty, page.nextCursor != next else {
        throw HarnessMonitorAPIError.invalidResponse
      }
      merged.items.append(contentsOf: page.items.filter { seen.insert($0.id).inserted })
      merged.itemRevisions.merge(page.itemRevisions) { _, latest in latest }
      cursor = page.nextCursor
      pages += 1
    }
    merged.nextCursor = nil
    return merged
  }
}
