import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("AppSearch suggestion snapshots")
struct AppSearchSuggestionSnapshotTests {
  @Test("Snapshot flattens results into stable native completions")
  func snapshotFlattensResultsIntoStableNativeCompletions() {
    let workerHit = AppSearchHit(
      domain: .agents,
      id: "worker-codex",
      title: "Codex Worker",
      subtitle: "SwiftUI performance",
      systemImage: AppSearchDomain.agents.systemImage,
      score: 0
    )
    let taskHit = AppSearchHit(
      domain: .tasks,
      id: "task-ui",
      title: "UI Performance",
      subtitle: "Audit",
      systemImage: AppSearchDomain.tasks.systemImage,
      score: 1
    )
    let results = AppSearchResults(
      query: "perf",
      primaryDomain: .agents,
      sections: [
        AppSearchSection(domain: .agents, hits: [workerHit], truncated: false),
        AppSearchSection(domain: .tasks, hits: [taskHit], truncated: false),
      ]
    )

    let snapshot = AppSearchSuggestionSnapshot(results: results)

    #expect(snapshot.rows.map(\.id) == ["agents:worker-codex", "tasks:task-ui"])
    #expect(
      snapshot.rows.map(\.displayTitle) == ["Codex Worker (Agents)", "UI Performance (Tasks)"]
    )
    #expect(snapshot.rows.map(\.completion) == ["Codex Worker", "UI Performance"])
    #expect(snapshot.firstHit == workerHit)
    #expect(snapshot.hit(matchingCompletion: " Codex Worker ") == workerHit)
    #expect(snapshot.hit(matchingCompletion: "UI Performance (Tasks)") == taskHit)
    #expect(snapshot.hit(matchingDisplayTitle: " Codex Worker (Agents) ") == workerHit)
    #expect(snapshot.hit(matchingDisplayTitle: "Codex Worker") == nil)
  }
}
