import Foundation

extension HarnessMonitorTaskBoardClientProtocol {
  public func pickTaskBoardDispatch(
    request _: TaskBoardDispatchPickRequest
  ) async throws -> TaskBoardDispatchPickResult {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func deliverTaskBoardDispatch(
    request _: TaskBoardDispatchDeliverRequest
  ) async throws -> TaskBoardDispatchDelivery {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func setPolicyCanvasSpawnRequiresLivePolicy(
    request _: PolicyCanvasSetSpawnRequiresLivePolicyRequest
  ) async throws -> PolicyCanvasWorkspace {
    throw HarnessMonitorAPIError.server(code: 501, message: "Policy canvas unavailable")
  }

  public func setPolicyCanvasSpawnKillSwitch(
    request _: PolicyCanvasSetSpawnKillSwitchRequest
  ) async throws -> PolicyCanvasWorkspace {
    throw HarnessMonitorAPIError.server(code: 501, message: "Policy canvas unavailable")
  }

  public func policyApprovalGrants() async throws -> [PolicyApprovalGrant] {
    throw HarnessMonitorAPIError.server(code: 501, message: "Policy approvals unavailable")
  }

  public func resolvePolicyApprovalGrant(
    request _: PolicyApprovalGrantResolveRequest
  ) async throws -> PolicyApprovalGrant {
    throw HarnessMonitorAPIError.server(code: 501, message: "Policy approvals unavailable")
  }

  public func revokePolicyApprovalGrant(
    request _: PolicyApprovalGrantRevokeRequest
  ) async throws -> PolicyApprovalGrant {
    throw HarnessMonitorAPIError.server(code: 501, message: "Policy approvals unavailable")
  }
}
