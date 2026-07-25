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
  /// `nextCursor` comes back `nil` only when the walk actually drained the
  /// selection. A walk that stopped early still carries the cursor it never
  /// consumed, so a truncated read is distinguishable from a complete one.
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
      if pages >= taskBoardItemPageLimit {
        break
      }
      let page = try await taskBoardItemPage(status: status, cursor: next)
      // A page that returned nothing advances nothing, whatever cursor came
      // back with it.
      if page.items.isEmpty {
        break
      }
      merged.items.append(contentsOf: page.items.filter { seen.insert($0.id).inserted })
      merged.itemRevisions.merge(page.itemRevisions) { _, latest in latest }
      cursor = page.nextCursor
      pages += 1
      // A cursor naming the resume point it was just given would re-fetch this
      // same page and append it again, so stop rather than keep asking.
      if page.nextCursor == next {
        break
      }
    }
    merged.nextCursor = cursor
    return merged
  }
}
