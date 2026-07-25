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
      page(ids: ["task-1", "task-2"], changeSeq: 41, nextCursor: "cursor-2"),
      page(ids: ["task-3"], changeSeq: 42, nextCursor: nil),
    ])

    let merged = try await source.mergedTaskBoardItemPages(status: nil)

    let requested = await source.requestedCursors
    #expect(requested == [nil, "cursor-2"])
    #expect(merged.items.map(\.id) == ["task-1", "task-2", "task-3"])
    #expect(merged.itemRevisions == ["task-1": 1, "task-2": 1, "task-3": 1])
    #expect(merged.itemsChangeSeq == 41)
    #expect(merged.nextCursor == nil)
  }

  @Test("stops on a page that returns no items even when a cursor comes back")
  func stopsOnAnEmptyPage() async throws {
    let source = StubTaskBoardPageSource(pages: [
      page(ids: ["task-1"], changeSeq: 7, nextCursor: "cursor-2"),
      page(ids: [], changeSeq: 7, nextCursor: "cursor-3"),
    ])

    let merged = try await source.mergedTaskBoardItemPages(status: nil)

    let requested = await source.requestedCursors
    #expect(requested == [nil, "cursor-2"])
    #expect(merged.items.map(\.id) == ["task-1"])
  }
}

private func page(
  ids: [String],
  changeSeq: Int64,
  nextCursor: String?
) -> TaskBoardListItemsResponseWire {
  TaskBoardListItemsResponseWire(
    items: ids.map(item(id:)),
    itemsChangeSeq: changeSeq,
    itemRevisions: Dictionary(uniqueKeysWithValues: ids.map { ($0, Int64(1)) }),
    totalMatched: UInt(ids.count),
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
