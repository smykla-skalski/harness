import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract for the project/worktree rollup, generated from
/// src/daemon/protocol/summaries.rs. ProjectSummary is the project list row and
/// nests Vec<WorktreeSummary>; both decode here through the plain decoder, proving
/// the daemon's nested snake_case payload lands in the typed wire form. generate
/// -only - the rich hand ProjectSummary/WorktreeSummary (Identifiable, Int counts)
/// stay until the projects reroute.
@Suite("Project summary wire graph")
struct SummariesProjectWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes a project with its nested worktrees")
  func decodesProjectWithWorktrees() throws {
    let project = try decoder.decode(
      ProjectSummaryWire.self, from: Data(projectSummaryPayloadFixture.utf8)
    )

    #expect(project.projectId == "proj-1")
    #expect(project.projectDir == "code/harness")
    #expect(project.activeSessionCount == 2)
    #expect(project.totalSessionCount == 5)

    #expect(project.worktrees.count == 1)
    let worktree = try #require(project.worktrees.first)
    #expect(worktree.checkoutId == "wt-1")
    #expect(worktree.name == "main")
    #expect(worktree.totalSessionCount == 3)
  }

  @Test("decodes a project with no worktrees and a null project dir")
  func decodesProjectWithoutWorktrees() throws {
    let project = try decoder.decode(
      ProjectSummaryWire.self, from: Data(projectSummaryNoWorktreesFixture.utf8)
    )
    #expect(project.projectDir == nil)
    #expect(project.worktrees.isEmpty)
    #expect(project.activeSessionCount == 0)
  }
}

private let projectSummaryPayloadFixture = """
  {
    "project_id": "proj-1",
    "name": "harness",
    "project_dir": "code/harness",
    "context_root": "sessions/harness",
    "active_session_count": 2,
    "total_session_count": 5,
    "worktrees": [
      {
        "checkout_id": "wt-1",
        "name": "main",
        "checkout_root": "code/harness",
        "context_root": "sessions/harness",
        "active_session_count": 1,
        "total_session_count": 3
      }
    ]
  }
  """

private let projectSummaryNoWorktreesFixture = """
  {
    "project_id": "proj-2",
    "name": "harness",
    "project_dir": null,
    "context_root": "sessions/harness",
    "active_session_count": 0,
    "total_session_count": 0,
    "worktrees": []
  }
  """
