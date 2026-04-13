import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("InspectorActionID key semantics")
struct InspectorActionIDTests {
  @Test("Create task key is namespaced by session")
  func createTaskKey() {
    let id = InspectorActionID.createTask(sessionID: "sess-1")
    #expect(id.key == "sess-1/createTask")
  }

  @Test("Assign task key includes task subject")
  func assignTaskKey() {
    let id = InspectorActionID.assignTask(sessionID: "sess-1", taskID: "task-42")
    #expect(id.key == "sess-1/assignTask/task-42")
  }

  @Test("Drop task key includes task subject")
  func dropTaskKey() {
    let id = InspectorActionID.dropTask(sessionID: "sess-1", taskID: "task-42")
    #expect(id.key == "sess-1/dropTask/task-42")
  }

  @Test("Update task status key includes task subject")
  func updateTaskStatusKey() {
    let id = InspectorActionID.updateTaskStatus(sessionID: "sess-1", taskID: "task-42")
    #expect(id.key == "sess-1/updateTaskStatus/task-42")
  }

  @Test("Checkpoint task key includes task subject")
  func checkpointTaskKey() {
    let id = InspectorActionID.checkpointTask(sessionID: "sess-1", taskID: "task-42")
    #expect(id.key == "sess-1/checkpointTask/task-42")
  }

  @Test("Update task queue policy key includes task subject")
  func updateTaskQueuePolicyKey() {
    let id = InspectorActionID.updateTaskQueuePolicy(sessionID: "sess-1", taskID: "task-42")
    #expect(id.key == "sess-1/updateTaskQueuePolicy/task-42")
  }

  @Test("Change role key includes agent subject")
  func changeRoleKey() {
    let id = InspectorActionID.changeRole(sessionID: "sess-1", agentID: "agent-7")
    #expect(id.key == "sess-1/changeRole/agent-7")
  }

  @Test("Remove agent key includes agent subject")
  func removeAgentKey() {
    let id = InspectorActionID.removeAgent(sessionID: "sess-1", agentID: "agent-7")
    #expect(id.key == "sess-1/removeAgent/agent-7")
  }

  @Test("Transfer leader key includes new leader subject")
  func transferLeaderKey() {
    let id = InspectorActionID.transferLeader(sessionID: "sess-1", newLeaderID: "agent-9")
    #expect(id.key == "sess-1/transferLeader/agent-9")
  }

  @Test("Observe session key uses session only")
  func observeSessionKey() {
    let id = InspectorActionID.observeSession(sessionID: "sess-1")
    #expect(id.key == "sess-1/observeSession")
  }

  @Test("End session key uses session only")
  func endSessionKey() {
    let id = InspectorActionID.endSession(sessionID: "sess-1")
    #expect(id.key == "sess-1/endSession")
  }

  @Test("Send signal key includes agent subject")
  func sendSignalKey() {
    let id = InspectorActionID.sendSignal(sessionID: "sess-1", agentID: "agent-7")
    #expect(id.key == "sess-1/sendSignal/agent-7")
  }

  @Test("Keys are distinct between sessions")
  func keysAreDistinctBetweenSessions() {
    let lhs = InspectorActionID.createTask(sessionID: "sess-1")
    let rhs = InspectorActionID.createTask(sessionID: "sess-2")
    #expect(lhs.key != rhs.key)
  }

  @Test("Keys are distinct between verbs on the same subject")
  func keysAreDistinctBetweenVerbs() {
    let lhs = InspectorActionID.assignTask(sessionID: "sess-1", taskID: "task-42")
    let rhs = InspectorActionID.dropTask(sessionID: "sess-1", taskID: "task-42")
    #expect(lhs.key != rhs.key)
  }

  @Test("Keys are distinct between subjects of the same verb")
  func keysAreDistinctBetweenSubjects() {
    let lhs = InspectorActionID.assignTask(sessionID: "sess-1", taskID: "task-1")
    let rhs = InspectorActionID.assignTask(sessionID: "sess-1", taskID: "task-2")
    #expect(lhs.key != rhs.key)
  }

  @Test("Equal payloads produce equal keys")
  func equalPayloadsProduceEqualKeys() {
    let lhs = InspectorActionID.createTask(sessionID: "sess-1")
    let rhs = InspectorActionID.createTask(sessionID: "sess-1")
    #expect(lhs.key == rhs.key)
    #expect(lhs == rhs)
  }

  @Test("Hashable conformance deduplicates Set membership")
  func hashableSetMembership() {
    let ids: Set<InspectorActionID> = [
      .createTask(sessionID: "sess-1"),
      .createTask(sessionID: "sess-1"),
      .assignTask(sessionID: "sess-1", taskID: "task-1"),
    ]
    #expect(ids.count == 2)
  }
}
