import AppIntents
import AppKit
import Foundation
import HarnessMonitorKit

public struct OpenTaskBoardIntent: AppIntent {
  public static var title: LocalizedStringResource { "Open Task Board" }
  public static var description: IntentDescription {
    IntentDescription(
      """
      Bring Harness Monitor to the front on the Task Board route. Pass an \
      item to surface it selected.
      """,
      categoryName: "Task Board",
      searchKeywords: ["task", "board", "todo", "open"]
    )
  }
  public static var openAppWhenRun: Bool { true }

  @Parameter(
    title: "Task",
    description: "Optional task to surface in the Task Board detail pane"
  )
  public var item: TaskBoardItemEntity?

  public init() {}

  public init(item: TaskBoardItemEntity?) {
    self.item = item
  }

  public func perform() async throws -> some IntentResult {
    let route = HarnessMonitorDeepLinkRoute.taskBoard(itemID: item?.id)
    if let url = HarnessMonitorDeepLinkRouter.url(for: route) {
      await MainActor.run {
        _ = NSWorkspace.shared.open(url)
      }
    }
    return .result()
  }
}
