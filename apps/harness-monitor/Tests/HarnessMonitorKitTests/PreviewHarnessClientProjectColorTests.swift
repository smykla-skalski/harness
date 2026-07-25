import Testing

@testable import HarnessMonitorKit

@Suite("Preview harness client project colors")
struct PreviewHarnessClientProjectColorTests {
  private func client() -> PreviewHarnessClient {
    PreviewHarnessClient(fixtures: .taskBoardBoardOnly, isLaunchAgentInstalled: true)
  }

  private func projects(_ client: PreviewHarnessClient) async throws
    -> [TaskBoardProjectSummary]
  {
    try await client.taskBoardProjects(status: nil)
  }

  /// The preview client stands in for a real board, so it has to reproduce the
  /// thing the mark exists for: several projects, several colors. One color
  /// across the board would let a broken card path look right in every preview.
  @Test("Preview projects do not share a color while the palette has room")
  func previewProjectsDoNotShareAColor() async throws {
    let client = client()
    for index in 0..<4 {
      _ = try await client.createTaskBoardItem(
        request: TaskBoardCreateItemRequest(
          title: "Item \(index)",
          body: "",
          priority: .medium,
          agentMode: .headless,
          tags: [],
          projectId: "acme/project-\(index)"
        )
      )
    }

    let catalog = try await projects(client)
    try #require(catalog.count > 1, "seeding should have produced several projects")
    #expect(
      Set(catalog.map(\.color)).count == catalog.count,
      "two preview projects landed on the same color with the palette not yet spent"
    )
  }

  @Test("A chosen color sticks and a reset gives it back")
  func aChosenColorSticksAndAResetGivesItBack() async throws {
    let client = client()
    let target = try #require(try await projects(client).first)
    let chosen: TaskBoardProjectColor =
      target.color == .graphite ? .pink : .graphite

    let updated = try await client.updateTaskBoardProject(
      request: TaskBoardProjectUpdateRequest(projectId: target.projectId, color: chosen)
    )
    #expect(updated.color == chosen)
    let afterSet = try await projects(client).first { $0.projectId == target.projectId }
    #expect(afterSet?.color == chosen, "the catalog every card reads has to show the edit")

    let reset = try await client.updateTaskBoardProject(
      request: TaskBoardProjectUpdateRequest(projectId: target.projectId, resetColor: true)
    )
    #expect(reset.color == target.color, "a reset returns the automatically assigned color")
  }

  /// Both halves of a two-sided edit are refused rather than silently ranked.
  /// A fixture that picked a winner would report success for an edit the caller
  /// never got, which is exactly the bug the daemon rule exists to prevent.
  @Test("A request that both sets and unsets a field is refused")
  func aRequestThatBothSetsAndUnsetsAFieldIsRefused() async throws {
    let client = client()
    let target = try #require(try await projects(client).first)

    await #expect(throws: HarnessMonitorAPIError.self) {
      try await client.updateTaskBoardProject(
        request: TaskBoardProjectUpdateRequest(
          projectId: target.projectId,
          color: .pink,
          resetColor: true
        )
      )
    }
    await #expect(throws: HarnessMonitorAPIError.self) {
      try await client.updateTaskBoardProject(
        request: TaskBoardProjectUpdateRequest(
          projectId: target.projectId,
          displayName: "Renamed",
          clearDisplayName: true
        )
      )
    }

    let unchanged = try await projects(client).first { $0.projectId == target.projectId }
    #expect(unchanged?.color == target.color, "a refused edit leaves the project alone")
  }

  @Test("An unregistered project is refused")
  func anUnregisteredProjectIsRefused() async throws {
    await #expect(throws: HarnessMonitorAPIError.self) {
      try await client().updateTaskBoardProject(
        request: TaskBoardProjectUpdateRequest(
          projectId: "project-ffffffffffffffffffffffffffffffff",
          color: .mint
        )
      )
    }
  }
}
