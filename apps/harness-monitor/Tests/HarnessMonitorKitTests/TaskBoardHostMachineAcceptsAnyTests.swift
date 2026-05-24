import Testing

@testable import HarnessMonitorKit

@Suite("Task board host machine dispatch picker filter")
struct TaskBoardHostMachineDispatchableItemsTests {
  @Test("Dispatch picker hides items that don't match host project types")
  func dispatchPickerHidesItemsThatDontMatchHostProjectTypes() {
    let webItem = makeItem(id: "web-1", targetProjectTypes: ["web"])
    let mobileItem = makeItem(id: "mobile-1", targetProjectTypes: ["mobile"])
    let universal = makeItem(id: "universal-1", targetProjectTypes: [])

    let result = TaskBoardHostMachine.dispatchableItems(
      [webItem, mobileItem, universal],
      machineProjectTypes: ["data"]
    )

    #expect(result.map(\.id) == ["universal-1"])
  }

  @Test("Dispatch picker keeps every item when host declares no project types")
  func dispatchPickerKeepsEveryItemWhenHostDeclaresNoProjectTypes() {
    let webItem = makeItem(id: "web-1", targetProjectTypes: ["web"])
    let mobileItem = makeItem(id: "mobile-1", targetProjectTypes: ["mobile"])

    let result = TaskBoardHostMachine.dispatchableItems(
      [webItem, mobileItem],
      machineProjectTypes: []
    )

    #expect(result.map(\.id) == ["web-1", "mobile-1"])
  }

  @Test("Dispatch picker keeps overlapping items")
  func dispatchPickerKeepsOverlappingItems() {
    let webData = makeItem(id: "wd-1", targetProjectTypes: ["web", "data"])
    let dataOnly = makeItem(id: "d-1", targetProjectTypes: ["data"])
    let mobileOnly = makeItem(id: "m-1", targetProjectTypes: ["mobile"])

    let result = TaskBoardHostMachine.dispatchableItems(
      [webData, dataOnly, mobileOnly],
      machineProjectTypes: ["data"]
    )

    #expect(result.map(\.id) == ["wd-1", "d-1"])
  }

  private func makeItem(id: String, targetProjectTypes: [String]) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: "Item \(id)",
      body: "",
      status: .todo,
      priority: .medium,
      tags: [],
      projectId: nil,
      targetProjectTypes: targetProjectTypes,
      agentMode: .headless,
      externalRefs: [],
      planning: TaskBoardPlanningState(),
      workflow: nil,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      createdAt: "2026-05-15T00:00:00Z",
      updatedAt: "2026-05-15T00:00:00Z",
      deletedAt: nil
    )
  }
}

@Suite("Task board host machine accepts any")
struct TaskBoardHostMachineAcceptsAnyTests {
  @Test("Empty item target project types route to every host")
  func emptyItemTargetProjectTypesRouteToEveryHost() {
    #expect(
      TaskBoardHostMachine.acceptsAny(
        machineProjectTypes: ["web"],
        itemTargetProjectTypes: []
      )
    )
    #expect(
      TaskBoardHostMachine.acceptsAny(
        machineProjectTypes: [],
        itemTargetProjectTypes: []
      )
    )
  }

  @Test("Empty machine project types accept every item")
  func emptyMachineProjectTypesAcceptEveryItem() {
    #expect(
      TaskBoardHostMachine.acceptsAny(
        machineProjectTypes: [],
        itemTargetProjectTypes: ["web"]
      )
    )
  }

  @Test("Matching project type accepts")
  func matchingProjectTypeAccepts() {
    #expect(
      TaskBoardHostMachine.acceptsAny(
        machineProjectTypes: ["web", "data"],
        itemTargetProjectTypes: ["data"]
      )
    )
  }

  @Test("No overlap rejects")
  func nonOverlappingProjectTypesReject() {
    #expect(
      !TaskBoardHostMachine.acceptsAny(
        machineProjectTypes: ["web"],
        itemTargetProjectTypes: ["mobile"]
      )
    )
  }

  @Test("Case-insensitive trimmed compare")
  func caseInsensitiveTrimmedCompare() {
    #expect(
      TaskBoardHostMachine.acceptsAny(
        machineProjectTypes: [" Web "],
        itemTargetProjectTypes: ["web"]
      )
    )
    #expect(
      TaskBoardHostMachine.acceptsAny(
        machineProjectTypes: ["WEB"],
        itemTargetProjectTypes: [" web "]
      )
    )
  }
}
