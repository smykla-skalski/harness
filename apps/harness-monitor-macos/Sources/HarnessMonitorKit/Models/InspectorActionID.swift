import Foundation

public enum InspectorActionID: Hashable, Sendable {
  case createTask(sessionID: String)
  case assignTask(sessionID: String, taskID: String)
  case dropTask(sessionID: String, taskID: String)
  case updateTaskStatus(sessionID: String, taskID: String)
  case checkpointTask(sessionID: String, taskID: String)
  case submitTaskForReview(sessionID: String, taskID: String)
  case claimTaskReview(sessionID: String, taskID: String)
  case submitTaskReview(sessionID: String, taskID: String)
  case respondTaskReview(sessionID: String, taskID: String)
  case arbitrateTask(sessionID: String, taskID: String)
  case applyImproverPatch(sessionID: String, issueID: String)
  case updateTaskQueuePolicy(sessionID: String, taskID: String)
  case changeRole(sessionID: String, agentID: String)
  case removeAgent(sessionID: String, agentID: String)
  case transferLeader(sessionID: String, newLeaderID: String)
  case observeSession(sessionID: String)
  case endSession(sessionID: String)
  case sendSignal(sessionID: String, agentID: String)
  case cancelSignal(sessionID: String, signalID: String)

  public var key: String {
    switch self {
    case .createTask(let sessionID):
      return "\(sessionID)/createTask"
    case .assignTask(let sessionID, let taskID):
      return "\(sessionID)/assignTask/\(taskID)"
    case .dropTask(let sessionID, let taskID):
      return "\(sessionID)/dropTask/\(taskID)"
    case .updateTaskStatus(let sessionID, let taskID):
      return "\(sessionID)/updateTaskStatus/\(taskID)"
    case .checkpointTask(let sessionID, let taskID):
      return "\(sessionID)/checkpointTask/\(taskID)"
    case .submitTaskForReview(let sessionID, let taskID):
      return "\(sessionID)/submitTaskForReview/\(taskID)"
    case .claimTaskReview(let sessionID, let taskID):
      return "\(sessionID)/claimTaskReview/\(taskID)"
    case .submitTaskReview(let sessionID, let taskID):
      return "\(sessionID)/submitTaskReview/\(taskID)"
    case .respondTaskReview(let sessionID, let taskID):
      return "\(sessionID)/respondTaskReview/\(taskID)"
    case .arbitrateTask(let sessionID, let taskID):
      return "\(sessionID)/arbitrateTask/\(taskID)"
    case .applyImproverPatch(let sessionID, let issueID):
      return "\(sessionID)/applyImproverPatch/\(issueID)"
    case .updateTaskQueuePolicy(let sessionID, let taskID):
      return "\(sessionID)/updateTaskQueuePolicy/\(taskID)"
    case .changeRole(let sessionID, let agentID):
      return "\(sessionID)/changeRole/\(agentID)"
    case .removeAgent(let sessionID, let agentID):
      return "\(sessionID)/removeAgent/\(agentID)"
    case .transferLeader(let sessionID, let newLeaderID):
      return "\(sessionID)/transferLeader/\(newLeaderID)"
    case .observeSession(let sessionID):
      return "\(sessionID)/observeSession"
    case .endSession(let sessionID):
      return "\(sessionID)/endSession"
    case .sendSignal(let sessionID, let agentID):
      return "\(sessionID)/sendSignal/\(agentID)"
    case .cancelSignal(let sessionID, let signalID):
      return "\(sessionID)/cancelSignal/\(signalID)"
    }
  }
}
