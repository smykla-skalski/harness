import Foundation
import HarnessMonitorKit

struct TaskBoardItemEditorDraft: Equatable {
  var title = ""
  var body = ""
  var status: TaskBoardStatus = .new
  var priority: TaskBoardPriority = .medium
  var tagsText = ""
  var projectId = ""
  var agentMode: TaskBoardAgentMode = .headless
  var planningSummary = ""
  var externalRefs: [TaskBoardExternalRefDraft] = []
  var sessionId = ""
  var workItemId = ""
  var approvedBy = ""
  var approvedAt = ""

  init() {}

  init(item: TaskBoardItem) {
    title = item.title
    body = item.body
    status = item.status
    priority = item.priority
    tagsText = item.tags.joined(separator: ", ")
    projectId = item.projectId ?? ""
    agentMode = item.agentMode
    planningSummary = item.planning.summary ?? ""
    externalRefs = item.externalRefs.map(TaskBoardExternalRefDraft.init(ref:))
    sessionId = item.sessionId ?? ""
    workItemId = item.workItemId ?? ""
    approvedBy = item.planning.approvedBy ?? ""
    approvedAt = item.planning.approvedAt ?? ""
  }

  var canSubmit: Bool {
    normalized(title) != nil
  }

  var createRequest: TaskBoardCreateItemRequest {
    TaskBoardCreateItemRequest(
      title: normalized(title) ?? "",
      body: body.trimmingCharacters(in: .whitespacesAndNewlines),
      priority: priority,
      agentMode: agentMode,
      tags: tags,
      projectId: normalized(projectId),
      externalRefs: materializedExternalRefs,
      planning: planningState,
      sessionId: normalized(sessionId),
      workItemId: normalized(workItemId)
    )
  }

  var updateRequest: TaskBoardUpdateItemRequest {
    TaskBoardUpdateItemRequest(
      title: normalized(title),
      body: body.trimmingCharacters(in: .whitespacesAndNewlines),
      status: status,
      priority: priority,
      agentMode: agentMode,
      tags: tags,
      projectId: normalized(projectId),
      clearProjectId: normalized(projectId) == nil,
      externalRefs: materializedExternalRefs,
      planning: planningState,
      sessionId: normalized(sessionId),
      clearSessionId: normalized(sessionId) == nil,
      workItemId: normalized(workItemId),
      clearWorkItemId: normalized(workItemId) == nil
    )
  }

  var tags: [String] {
    tagsText
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  var materializedExternalRefs: [TaskBoardExternalRef] {
    externalRefs.compactMap(\.externalRef)
  }

  var planningState: TaskBoardPlanningState {
    TaskBoardPlanningState(
      summary: normalized(planningSummary),
      approvedBy: normalized(approvedBy),
      approvedAt: normalized(approvedAt)
    )
  }

  private func normalized(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

struct TaskBoardExternalRefDraft: Equatable, Identifiable {
  var id = UUID()
  var provider: TaskBoardExternalRefProvider = .gitHub
  var externalId = ""
  var url = ""

  init() {}

  init(ref: TaskBoardExternalRef) {
    provider = ref.provider
    externalId = ref.externalId
    url = ref.url ?? ""
  }

  var externalRef: TaskBoardExternalRef? {
    let externalId = self.externalId.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = self.url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !externalId.isEmpty else {
      return nil
    }
    return TaskBoardExternalRef(provider: provider, externalId: externalId, url: url.nilIfEmpty)
  }
}

extension String {
  fileprivate var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
