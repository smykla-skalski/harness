import Foundation
import Testing

@testable import HarnessMonitorKit

/// Serves scripted pages and records the cursor each read asked for.
private actor StubTaskBoardPageSource: TaskBoardItemPageSource {
  private let pages: [TaskBoardListItemsResponseWire]
  private(set) var requestedCursors: [String?] = []

  init(pages: [TaskBoardListItemsResponseWire]) {
    self.pages = pages
  }

  func taskBoardItemPage(
    status: TaskBoardStatus?,
    cursor: String?
  ) async throws -> TaskBoardListItemsResponseWire {
    requestedCursors.append(cursor)
    return pages[min(requestedCursors.count - 1, pages.count - 1)]
  }
}

/// The daemon bounds every task-board list response, so the app reads the whole
/// board by walking cursors. These cover the walk's two ways of ending: a page
/// without a cursor, and a cursor that stops producing items.
@Suite("Task board item page walk")
struct TaskBoardItemPageWalkTests {
  @Test("folds every page into one response and keeps the first change sequence")
  func foldsEveryPage() async throws {
    let source = StubTaskBoardPageSource(pages: [
      page(ids: ["task-1", "task-2"], totalMatched: 3, changeSeq: 41, nextCursor: "cursor-2"),
      page(ids: ["task-3"], totalMatched: 3, changeSeq: 42, nextCursor: nil),
    ])

    let merged = try await source.mergedTaskBoardItemPages(status: nil)

    let requested = await source.requestedCursors
    #expect(requested == [nil, "cursor-2"])
    #expect(merged.items.map(\.id) == ["task-1", "task-2", "task-3"])
    #expect(merged.itemRevisions == ["task-1": 1, "task-2": 1, "task-3": 1])
    #expect(merged.itemsChangeSeq == 41)
    #expect(merged.nextCursor == nil)
  }

  /// A cursor naming the resume point it was just given can never drain, and
  /// every caller folds this result into a whole-board value, so the walk
  /// fails rather than handing back the part it read.
  @Test("fails on a cursor that never advances")
  func failsOnANonAdvancingCursor() async throws {
    let source = StubTaskBoardPageSource(pages: [
      page(ids: ["task-1"], totalMatched: 9, changeSeq: 3, nextCursor: "cursor-stuck"),
      page(ids: ["task-2"], totalMatched: 9, changeSeq: 3, nextCursor: "cursor-stuck"),
    ])

    await #expect(throws: HarnessMonitorAPIError.invalidResponse) {
      try await source.mergedTaskBoardItemPages(status: nil)
    }
  }

  /// The daemon never pairs a cursor with an empty page, so that shape is a
  /// board this walk cannot finish reading rather than the end of one.
  @Test("fails on a page that returns no items")
  func failsOnAnEmptyPage() async throws {
    let source = StubTaskBoardPageSource(pages: [
      page(ids: ["task-1"], totalMatched: 1, changeSeq: 7, nextCursor: "cursor-2"),
      page(ids: [], totalMatched: 1, changeSeq: 7, nextCursor: "cursor-3"),
    ])

    await #expect(throws: HarnessMonitorAPIError.invalidResponse) {
      try await source.mergedTaskBoardItemPages(status: nil)
    }
  }

  /// The stall check above only catches a cursor that names the resume point it
  /// was just given. A cursor whose anchor was deleted between two reads resumes
  /// at that anchor's slot, so a page can re-serve a row while still advancing
  /// to a different cursor - and duplicate ids break `ForEach(..., id: \.id)`.
  @Test("folds a row a later page re-served under a different cursor")
  func foldsARowReServedUnderADifferentCursor() async throws {
    let source = StubTaskBoardPageSource(pages: [
      page(
        ids: ["task-1", "task-2", "task-3"], totalMatched: 4, changeSeq: 9,
        nextCursor: "cursor-2"),
      page(
        ids: ["task-2", "task-3", "task-4"], totalMatched: 4, changeSeq: 9,
        nextCursor: nil),
    ])

    let merged = try await source.mergedTaskBoardItemPages(status: nil)

    #expect(merged.items.map(\.id) == ["task-1", "task-2", "task-3", "task-4"])
    #expect(merged.nextCursor == nil)
  }

  /// A page that repeats a row inside itself must not reach the caller either.
  @Test("folds a row a single page repeated")
  func foldsARowRepeatedWithinOnePage() async throws {
    let source = StubTaskBoardPageSource(pages: [
      page(ids: ["task-1", "task-1", "task-2"], totalMatched: 2, changeSeq: 9, nextCursor: nil)
    ])

    let merged = try await source.mergedTaskBoardItemPages(status: nil)

    #expect(merged.items.map(\.id) == ["task-1", "task-2"])
  }
}

/// `totalMatched` counts the whole matched selection, not the page, so every
/// page of one scenario reports the same total.
private func page(
  ids: [String],
  totalMatched: UInt,
  changeSeq: Int64,
  nextCursor: String?
) -> TaskBoardListItemsResponseWire {
  TaskBoardListItemsResponseWire(
    items: ids.map(item(id:)),
    itemsChangeSeq: changeSeq,
    // Tolerates a repeated id so a scenario can script a page that re-serves a
    // row the walk is expected to fold away.
    itemRevisions: Dictionary(ids.map { ($0, Int64(1)) }, uniquingKeysWith: { first, _ in first }),
    totalMatched: totalMatched,
    nextCursor: nextCursor
  )
}

private func item(id: String) -> TaskBoardItemWire {
  TaskBoardItemWire(
    schemaVersion: 1,
    id: id,
    title: id,
    createdAt: "2026-07-25T00:00:00Z",
    updatedAt: "2026-07-25T00:00:00Z"
  )
}
