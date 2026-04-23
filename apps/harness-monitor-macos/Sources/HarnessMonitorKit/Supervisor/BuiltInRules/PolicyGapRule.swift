import Foundation

/// Policy-gap teaching rule. Phase 2 worker 14 implements per source plan Task 18: trigger on
/// observer issues with `code` not present in the Swift-side `KnownClassifierCodes` constant;
/// aggressive default logs the event, cautious path queues an informational decision so the
/// user can teach a new pattern. Phase 2 also seeds the `KnownClassifierCodes` constant.
public struct PolicyGapRule: PolicyRule {
  public let id = "policy-gap"
  public let name = "Policy Gap"
  public let version = 1
  public let parameters = PolicyParameterSchema(fields: [])

  // Drift check: keep this Swift mirror in sync with Rust `IssueCode::ALL` in
  // `src/observe/types/issue_code.rs`.
  public static let knownClassifierCodes: Set<String> = [
    "absolute_manifest_path_used",
    "agent_guard_denial_loop",
    "agent_repeated_error",
    "agent_skill_misuse",
    "agent_stalled_progress",
    "api_rate_limit_detected",
    "auth_flow_triggered",
    "build_or_lint_failure",
    "closeout_verdict_pending",
    "corporate_cluster_context_detected",
    "cross_agent_file_conflict",
    "direct_kubectl_validate_usage",
    "direct_managed_file_write",
    "direct_task_output_file_read",
    "empty_kubeconfig",
    "file_edit_churn",
    "group_reported_without_capture",
    "harness_cli_error_output",
    "harness_create_command_failure",
    "harness_hook_code_triggered",
    "harness_infrastructure_misconfiguration",
    "hook_denied_tool_call",
    "incomplete_writer_output",
    "invalid_harness_subcommand_used",
    "jq_error_in_command_output",
    "manifest_created_during_run",
    "manifest_fix_prompt_shown",
    "manifest_runtime_failure",
    "manual_env_prefix_construction",
    "manual_export_construction",
    "manual_kubeconfig_construction",
    "manual_payload_recovery",
    "missing_claude_session_id",
    "missing_connection_or_env_var",
    "non_zero_exit_code",
    "payload_wrapped_in_json_tags",
    "pod_container_runtime_failure",
    "python_traceback_output",
    "python_used_in_bash_output",
    "python_used_in_bash_tool_use",
    "raw_cluster_make_target_used",
    "release_kumactl_binary_used",
    "repeated_kubectl_query_for_same_resource",
    "resource_not_cleaned_up_before_group_end",
    "runner_state_event_not_supported",
    "runner_state_machine_stale",
    "runtime_deviation_prompt_shown",
    "shell_alias_interference",
    "short_skill_name_in_skill_file",
    "sleep_prefix_before_harness_command",
    "subagent_manual_recovery",
    "subagent_permission_failure",
    "suite_deviation_detected",
    "tool_usage_error_output",
    "unauthorized_git_commit_during_run",
    "uncommitted_source_code_edit",
    "unverified_recursive_remove",
    "user_frustration_detected",
    "validator_install_prompt_shown",
    "verification_output_truncated",
    "workflow_state_error_output",
    "wrong_skill_cross_reference",
  ]

  public init() {}

  public func defaultBehavior(for actionKey: String) -> RuleDefaultBehavior {
    _ = actionKey
    return .aggressive
  }

  public func evaluate(
    snapshot: SessionsSnapshot,
    context: PolicyContext
  ) async -> [PolicyAction] {
    unknownCodes(in: snapshot).flatMap { unknownCode in
      actions(
        for: unknownCode,
        snapshotID: snapshot.id,
        sessionID: firstSessionID(for: unknownCode, in: snapshot)
      ).filter { !context.recentActionKeys.contains($0.actionKey) }
    }
  }

  private func unknownCodes(in snapshot: SessionsSnapshot) -> [String] {
    let codes = snapshot.sessions
      .flatMap(\.observerIssues)
      .map(\.code)
      .filter { !Self.knownClassifierCodes.contains($0) }
    return Array(Set(codes)).sorted()
  }

  private func firstSessionID(
    for code: String,
    in snapshot: SessionsSnapshot
  ) -> String? {
    snapshot.sessions.first { session in
      session.observerIssues.contains { $0.code == code }
    }?.id
  }

  private func actions(
    for unknownCode: String,
    snapshotID: String,
    sessionID: String?
  ) -> [PolicyAction] {
    let escapedCode = unknownCode.replacingOccurrences(of: "\"", with: "\\\"")
    let logID = "policy-gap-log-\(unknownCode)"
    let decisionID = "policy-gap-decision-\(unknownCode)"
    let message = "Unknown classifier code detected: \(unknownCode)"
    let contextJSON =
      """
      {"snapshotID":"\(snapshotID)","unknownCode":"\(escapedCode)","sessionID":\(jsonString(sessionID))}
      """
    let suggestedActionsJSON =
      """
      [{"kind":"teachClassifierCode","code":"\(escapedCode)"}]
      """

    return [
      .logEvent(
        .init(id: logID, ruleID: id, snapshotID: snapshotID, message: message)
      ),
      .queueDecision(
        .init(
          id: decisionID,
          severity: .info,
          ruleID: id,
          sessionID: sessionID,
          agentID: nil,
          taskID: nil,
          summary: "Teach supervisor about unknown classifier code: \(unknownCode)",
          contextJSON: contextJSON,
          suggestedActionsJSON: suggestedActionsJSON
        )
      ),
    ]
  }

  private func jsonString(_ value: String?) -> String {
    guard let value else { return "null" }
    let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }
}
