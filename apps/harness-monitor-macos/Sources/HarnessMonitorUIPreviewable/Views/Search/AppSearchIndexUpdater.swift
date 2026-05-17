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

/// Drives ``AppSearchIndex`` re-indexing from a zero-size anchor rather
/// than wrapping the full session window. Each domain's `.task(id:)` is
/// attached only while search is active, then cancels and reschedules
/// whenever its signature changes. Closed search keeps these task-state
/// nodes out of the expensive session layout graph so startup, sidebar,
/// and timeline churn do not create no-op reindex transactions.
///
/// The active-flag is read directly from the shared
/// ``AppSearchModel`` rather than `@Environment`. The host modifier
/// sits INSIDE this updater in the view tree, and SwiftUI environment
/// values flow downward only — an env value set by the host would
/// never reach this updater. Sharing the @Observable model sidesteps
/// the env-direction trap entirely.
///
/// The decisions snapshot crosses the actor boundary as prebuilt
/// ``DecisionSearchProjection`` values captured during the session
/// decision-cache refresh. `Decision` is an `@Model` class and is not
/// Sendable, so this view never maps decision rows while search opens.
struct AppSearchIndexUpdater: View {
  let model: AppSearchModel
  let index: AppSearchIndex
  let agents: [AgentRegistration]
  let decisionProjections: [DecisionSearchProjection]
  let tasks: [WorkItem]
  let events: [TimelineEntry]

  @ViewBuilder var body: some View {
    if model.isPresented {
      Color.clear
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
        .task(id: agentSignature) {
          await index.reindex(agents: agents)
        }
        .task(id: decisionSignature) {
          await index.reindex(decisions: decisionProjections)
        }
        .task(id: taskSignature) {
          await index.reindex(tasks: tasks)
        }
        .task(id: eventSignature) {
          await index.reindex(events: events)
        }
    } else {
      Color.clear
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
  }

  private var agentSignature: AppSearchDomainSignature {
    AppSearchDomainSignature(count: agents.count, lastID: agents.last?.agentId)
  }

  private var decisionSignature: AppSearchDomainSignature {
    AppSearchDomainSignature(
      count: decisionProjections.count,
      lastID: decisionProjections.last?.id
    )
  }

  private var taskSignature: AppSearchDomainSignature {
    AppSearchDomainSignature(count: tasks.count, lastID: tasks.last?.taskId)
  }

  private var eventSignature: AppSearchDomainSignature {
    AppSearchDomainSignature(count: events.count, lastID: events.last?.entryId)
  }
}
