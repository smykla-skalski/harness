import Testing

@testable import HarnessMonitorKit

@Suite("WebSocket RPC method catalog")
struct WebSocketRPCMethodTests {
  @Test("WebSocket RPC catalog carries parity method names")
  func rpcCatalogRawValues() {
    #expect(WebSocketRPCMethod.bridgeReconfigure.rawValue == "bridge.reconfigure")
    #expect(WebSocketRPCMethod.sessionAdopt.rawValue == "session.adopt")
    #expect(WebSocketRPCMethod.managedAgentInput.rawValue == "managed_agent.input")
    #expect(WebSocketRPCMethod.voiceFinishSession.rawValue == "voice.finish_session")
    #expect(WebSocketRPCMethod.taskBoardCreate.rawValue == "task_board.create")
    #expect(WebSocketRPCMethod.taskBoardList.rawValue == "task_board.list")
    #expect(WebSocketRPCMethod.taskBoardGet.rawValue == "task_board.get")
    #expect(WebSocketRPCMethod.taskBoardUpdate.rawValue == "task_board.update")
    #expect(WebSocketRPCMethod.taskBoardDelete.rawValue == "task_board.delete")
    #expect(WebSocketRPCMethod.taskBoardSync.rawValue == "task_board.sync")
    #expect(WebSocketRPCMethod.taskBoardDispatch.rawValue == "task_board.dispatch")
    #expect(WebSocketRPCMethod.taskBoardEvaluate.rawValue == "task_board.evaluate")
    #expect(WebSocketRPCMethod.taskBoardAudit.rawValue == "task_board.audit")
    #expect(WebSocketRPCMethod.taskBoardProjects.rawValue == "task_board.projects")
    #expect(WebSocketRPCMethod.taskBoardMachines.rawValue == "task_board.machines")
    #expect(
      WebSocketRPCMethod.taskBoardOrchestratorStatus.rawValue
        == "task_board.orchestrator_status"
    )
    #expect(
      WebSocketRPCMethod.taskBoardOrchestratorStart.rawValue == "task_board.orchestrator_start"
    )
    #expect(WebSocketRPCMethod.taskBoardOrchestratorStop.rawValue == "task_board.orchestrator_stop")
    #expect(
      WebSocketRPCMethod.taskBoardOrchestratorRunOnce.rawValue
        == "task_board.orchestrator_run_once"
    )
    #expect(
      WebSocketRPCMethod.taskBoardOrchestratorSettingsGet.rawValue
        == "task_board.orchestrator_settings_get"
    )
    #expect(
      WebSocketRPCMethod.taskBoardOrchestratorSettingsUpdate.rawValue
        == "task_board.orchestrator_settings_update"
    )
    #expect(
      WebSocketRPCMethod.taskBoardOrchestratorRuntimeConfigGet.rawValue
        == "task_board.orchestrator_runtime_config_get"
    )
    #expect(
      WebSocketRPCMethod.taskBoardOrchestratorRuntimeConfigUpdate.rawValue
        == "task_board.orchestrator_runtime_config_update"
    )
    #expect(
      WebSocketRPCMethod.taskBoardOrchestratorGitHubTokensSync.rawValue
        == "task_board.orchestrator_github_tokens_sync"
    )
    #expect(
      WebSocketRPCMethod.taskBoardOrchestratorTodoistTokenSync.rawValue
        == "task_board.orchestrator_todoist_token_sync"
    )
  }

  @Test("WebSocket RPC catalog carries policy and review method names")
  func rpcCatalogPolicyAndReviewRawValues() {
    #expect(
      WebSocketRPCMethod.policyCanvasWorkspaceGet.rawValue
        == "policy_canvas.workspace_get"
    )
    #expect(
      WebSocketRPCMethod.policyCanvasCreate.rawValue
        == "policy_canvas.create"
    )
    #expect(
      WebSocketRPCMethod.policyCanvasDuplicate.rawValue
        == "policy_canvas.duplicate"
    )
    #expect(
      WebSocketRPCMethod.policyCanvasRename.rawValue
        == "policy_canvas.rename"
    )
    #expect(
      WebSocketRPCMethod.policyCanvasSetActive.rawValue
        == "policy_canvas.set_active"
    )
    #expect(
      WebSocketRPCMethod.policyCanvasDelete.rawValue
        == "policy_canvas.delete"
    )
    #expect(
      WebSocketRPCMethod.policyPipelineGet.rawValue
        == "policy_pipeline.get"
    )
    #expect(
      WebSocketRPCMethod.policyPipelineSaveDraft.rawValue
        == "policy_pipeline.save_draft"
    )
    #expect(
      WebSocketRPCMethod.policyPipelineSimulate.rawValue
        == "policy_pipeline.simulate"
    )
    #expect(
      WebSocketRPCMethod.policyPipelinePromote.rawValue
        == "policy_pipeline.promote"
    )
    #expect(
      WebSocketRPCMethod.policyPipelineMakeLive.rawValue
        == "policy_pipeline.make_live"
    )
    #expect(
      WebSocketRPCMethod.policyPipelineGoLiveDiff.rawValue
        == "policy_pipeline.go_live_diff"
    )
    #expect(
      WebSocketRPCMethod.policyPipelineReplay.rawValue
        == "policy_pipeline.replay"
    )
    #expect(
      WebSocketRPCMethod.policyPipelineAudit.rawValue
        == "policy_pipeline.audit"
    )
    #expect(WebSocketRPCMethod.taskSubmitForReview.rawValue == "task.submit_for_review")
    #expect(WebSocketRPCMethod.taskClaimReview.rawValue == "task.claim_review")
    #expect(WebSocketRPCMethod.taskSubmitReview.rawValue == "task.submit_review")
    #expect(WebSocketRPCMethod.taskRespondReview.rawValue == "task.respond_review")
    #expect(WebSocketRPCMethod.taskArbitrate.rawValue == "task.arbitrate")
    #expect(WebSocketRPCMethod.improverApply.rawValue == "improver.apply")
  }
}
