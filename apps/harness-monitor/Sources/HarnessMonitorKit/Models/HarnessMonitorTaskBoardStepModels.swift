import Foundation

public struct TaskBoardDispatchSelection: Equatable, Sendable {
  public let item: TaskBoardItem
  public let plan: TaskBoardDispatchPlan

  public init(item: TaskBoardItem, plan: TaskBoardDispatchPlan) {
    self.item = item
    self.plan = plan
  }
}

public struct TaskBoardDispatchPickResult: Equatable, Sendable {
  public let selection: TaskBoardDispatchSelection?

  public init(selection: TaskBoardDispatchSelection? = nil) {
    self.selection = selection
  }
}

public struct TaskBoardDispatchDelivery: Equatable, Sendable {
  public let intentId: String
  public let applied: TaskBoardDispatchAppliedTask
  public let renderedPrompt: String
  public let startedAgent: ManagedAgentSnapshot?

  public init(
    intentId: String,
    applied: TaskBoardDispatchAppliedTask,
    renderedPrompt: String,
    startedAgent: ManagedAgentSnapshot? = nil
  ) {
    self.intentId = intentId
    self.applied = applied
    self.renderedPrompt = renderedPrompt
    self.startedAgent = startedAgent
  }
}

extension TaskBoardDispatchSelection {
  init(wire: TaskBoardDispatchPickSelection) {
    self.init(
      item: TaskBoardItem(wire: wire.item),
      plan: TaskBoardDispatchPlan(wire: wire.plan)
    )
  }
}

extension TaskBoardDispatchPickResult {
  init(wire: TaskBoardDispatchPickResponse) {
    self.init(selection: wire.selection.map(TaskBoardDispatchSelection.init(wire:)))
  }
}

extension TaskBoardDispatchDelivery {
  init(wire: TaskBoardDispatchDeliverResponse) throws {
    self.init(
      intentId: wire.intentId,
      applied: TaskBoardDispatchAppliedTask(wire: wire.applied),
      renderedPrompt: wire.renderedPrompt,
      startedAgent: try wire.startedAgent.map(ManagedAgentSnapshot.init(wire:))
    )
  }
}
