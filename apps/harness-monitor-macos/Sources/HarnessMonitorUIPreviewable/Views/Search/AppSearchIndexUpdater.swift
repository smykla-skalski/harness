import HarnessMonitorKit
import SwiftUI

/// Cheap per-domain change signature. The view layer derives it from
/// the live data once per body eval; only a signature change triggers
/// re-tokenisation inside the actor. Count + last-id catches append /
/// remove / reorder at the tail; for edit-only updates the surrounding
/// view's body re-evaluates often enough that the next append still
/// reflects the edit.
private struct AppSearchDomainSignature: Hashable {
  let count: Int
  let lastID: String?
}

/// Joint task-id key so re-indexing fires when the search field opens
/// (cold start) and when an in-flight session adds new records while
/// the user is searching.
private struct AppSearchReindexTrigger: Hashable {
  let active: Bool
  let signature: AppSearchDomainSignature
}

/// Drives ``AppSearchIndex`` re-indexing from the four session-window
/// data sources. Each domain's `.task(id:)` cancels and reschedules
/// whenever its signature OR the `harnessSearchActive` env value
/// changes; reindexing is skipped when the search field is not
/// presented so a session with thousands of incoming timeline events
/// does not rebuild four corpora on every append.
///
/// The decisions snapshot crosses the actor boundary as
/// ``DecisionSearchProjection`` values built on the MainActor before
/// the actor hop. `Decision` is an `@Model` class and is not Sendable.
struct AppSearchIndexUpdater: ViewModifier {
  let index: AppSearchIndex
  let agents: [AgentRegistration]
  let decisions: [Decision]
  let tasks: [WorkItem]
  let events: [TimelineEntry]

  @Environment(\.harnessSearchActive)
  private var searchActive: Bool

  func body(content: Content) -> some View {
    content
      .task(id: AppSearchReindexTrigger(active: searchActive, signature: agentSignature)) {
        guard searchActive else { return }
        await index.reindex(agents: agents)
      }
      .task(id: AppSearchReindexTrigger(active: searchActive, signature: decisionSignature)) {
        guard searchActive else { return }
        let projections = decisions.map { decision in
          DecisionSearchProjection(
            id: decision.id,
            summary: decision.summary,
            ruleID: decision.ruleID,
            agentID: decision.agentID,
            taskID: decision.taskID
          )
        }
        await index.reindex(decisions: projections)
      }
      .task(id: AppSearchReindexTrigger(active: searchActive, signature: taskSignature)) {
        guard searchActive else { return }
        await index.reindex(tasks: tasks)
      }
      .task(id: AppSearchReindexTrigger(active: searchActive, signature: eventSignature)) {
        guard searchActive else { return }
        await index.reindex(events: events)
      }
  }

  private var agentSignature: AppSearchDomainSignature {
    AppSearchDomainSignature(count: agents.count, lastID: agents.last?.agentId)
  }

  private var decisionSignature: AppSearchDomainSignature {
    AppSearchDomainSignature(count: decisions.count, lastID: decisions.last?.id)
  }

  private var taskSignature: AppSearchDomainSignature {
    AppSearchDomainSignature(count: tasks.count, lastID: tasks.last?.taskId)
  }

  private var eventSignature: AppSearchDomainSignature {
    AppSearchDomainSignature(count: events.count, lastID: events.last?.entryId)
  }
}
