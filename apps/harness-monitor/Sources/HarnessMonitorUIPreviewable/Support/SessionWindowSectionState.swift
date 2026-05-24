import Foundation
import Observation

@MainActor
@Observable
public final class SessionWindowSectionState {
  public var routeSelection: SessionWindowRoute = .overview
  public var agentID: String?
  public var codexRunID: String?
  public var openRouterRunID: String?
  public var decisionID: String?
  public var taskID: String?
  public var timelineEntryID: String?
  public var createDrafts: [SessionCreateKind: SessionCreateDraft] = [:]

  public init() {}

  public func remember(_ selection: SessionSelection) {
    switch selection {
    case .route(let route):
      assign(\.routeSelection, route)
    case .agent(_, let agentID):
      assign(\.agentID, agentID)
    case .codexRun(_, let runID):
      assign(\.codexRunID, runID)
    case .openRouterRun(_, let runID):
      assign(\.openRouterRunID, runID)
    case .decision(_, let decisionID):
      assign(\.decisionID, decisionID)
    case .task(_, let taskID):
      assign(\.taskID, taskID)
    case .create(let draft):
      guard createDrafts[draft.kind] != draft else { return }
      createDrafts[draft.kind] = draft
    }
  }

  private func assign<Value: Equatable>(
    _ keyPath: ReferenceWritableKeyPath<SessionWindowSectionState, Value>,
    _ value: Value
  ) {
    guard self[keyPath: keyPath] != value else { return }
    self[keyPath: keyPath] = value
  }

  public func hasDraft(_ kind: SessionCreateKind) -> Bool {
    guard let draft = createDrafts[kind] else { return false }
    return !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}
