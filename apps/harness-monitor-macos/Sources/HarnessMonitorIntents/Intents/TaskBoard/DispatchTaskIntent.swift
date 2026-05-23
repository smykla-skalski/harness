import AppIntents
import Foundation
import HarnessMonitorKit

public struct DispatchTaskIntent: AppIntent {
  public static var title: LocalizedStringResource { "Dispatch Task" }
  public static var description: IntentDescription {
    IntentDescription(
      "Dispatch a Task Board item to its orchestrator. Confirms before running.",
      categoryName: "Task Board",
      searchKeywords: ["dispatch", "run", "execute", "task"]
    )
  }

  @Parameter(title: "Task") public var item: TaskBoardItemEntity

  let source: TaskBoardItemSource

  public init() {
    self.source = DaemonTaskBoardItemSource()
  }

  init(item: TaskBoardItemEntity, source: TaskBoardItemSource) {
    self.source = source
    self.item = item
  }

  public func perform() async throws -> some IntentResult & ProvidesDialog {
    try await requestConfirmation(
      dialog: IntentDialog("Dispatch \(item.title)?")
    )
    try await applyDispatch()
    return .result(dialog: IntentDialog("Dispatched \(item.title)."))
  }

  func applyDispatch() async throws {
    try await source.dispatch(itemID: item.id)
  }
}
