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
  /// Every page must carry the first page's `itemsChangeSeq`. The daemon binds
  /// cursors to that sequence, and checking it here keeps an older or malformed
  /// daemon from returning a mixed board snapshot.
  ///
  /// A walk that cannot drain the selection throws rather than answering with
  /// what it has. Every caller folds this into a whole-board value - one of
  /// them into `TaskBoardListItemsSnapshot`, which has nowhere to record that
  /// the read stopped early - so a partial result would be indistinguishable
  /// from a complete one at every call site.
  ///
  /// Sequence-bound cursors prevent overlap in valid responses. Ids are still
  /// tracked so a malformed overlapping page cannot put duplicate identities
  /// into `ForEach(..., id: \.id)`.
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
      guard
        page.itemsChangeSeq == merged.itemsChangeSeq,
        !page.items.isEmpty,
        page.nextCursor != next
      else {
        throw HarnessMonitorAPIError.invalidResponse
      }
      merged.items.append(contentsOf: page.items.filter { seen.insert($0.id).inserted })
      merged.itemRevisions.merge(page.itemRevisions) { current, _ in current }
      cursor = page.nextCursor
      pages += 1
    }
    merged.nextCursor = nil
    return merged
  }
}
