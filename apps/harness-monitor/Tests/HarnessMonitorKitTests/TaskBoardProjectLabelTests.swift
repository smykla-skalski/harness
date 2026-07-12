import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Task board project labels")
struct TaskBoardProjectLabelTests {
  @Test("Unique repository names omit their owner")
  func uniqueRepositoryNamesOmitTheirOwner() {
    let resolver = TaskBoardProjectLabelResolver(
      projectIDs: ["alpha/widget", "beta/control-plane"]
    )

    #expect(resolver.label(for: "alpha/widget") == "widget")
    #expect(resolver.label(for: "beta/control-plane") == "control-plane")
  }

  @Test("Ambiguous repository names retain every owner")
  func ambiguousRepositoryNamesRetainEveryOwner() {
    let resolver = TaskBoardProjectLabelResolver(
      projectIDs: ["alpha/console", "beta/CONSOLE", "gamma/worker"]
    )

    #expect(resolver.label(for: "alpha/console") == "alpha/console")
    #expect(resolver.label(for: "beta/CONSOLE") == "beta/CONSOLE")
    #expect(resolver.label(for: "gamma/worker") == "worker")
  }

  @Test("Repeated cards from one repository remain unambiguous")
  func repeatedCardsFromOneRepositoryRemainUnambiguous() {
    let resolver = TaskBoardProjectLabelResolver(
      projectIDs: ["alpha/console", "alpha/console", "ALPHA/CONSOLE"]
    )

    #expect(resolver.label(for: "alpha/console") == "console")
    #expect(resolver.label(for: "ALPHA/CONSOLE") == "CONSOLE")
  }

  @Test("Non repository project identifiers remain unchanged")
  func nonRepositoryProjectIdentifiersRemainUnchanged() {
    let projectIDs = ["project-1", "owner/repo/extra", "/repo", "owner/"]
    let resolver = TaskBoardProjectLabelResolver(projectIDs: projectIDs)

    for projectID in projectIDs {
      #expect(resolver.label(for: projectID) == projectID)
    }
  }

  @Test("Full repository names can be forced")
  func fullRepositoryNamesCanBeForced() {
    let resolver = TaskBoardProjectLabelResolver(projectIDs: ["alpha/widget"])

    #expect(
      resolver.label(for: "alpha/widget", alwaysShowFullName: true) == "alpha/widget"
    )
  }
}
