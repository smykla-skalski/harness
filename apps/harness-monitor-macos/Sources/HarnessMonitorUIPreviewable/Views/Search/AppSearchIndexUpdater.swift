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

/// Drives ``AppSearchIndex`` re-indexing from the four session-window
/// data sources. Each domain's `.task(id: signature)` cancels and
/// reschedules whenever its signature changes; an unchanged signature
/// is a no-op so a scroll or selection change never triggers reindex.
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

  func body(content: Content) -> some View {
    content
      .task(id: agentSignature) {
        await index.reindex(agents: agents)
      }
      .task(id: decisionSignature) {
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
      .task(id: taskSignature) {
        await index.reindex(tasks: tasks)
      }
      .task(id: eventSignature) {
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
