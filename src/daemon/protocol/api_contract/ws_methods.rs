pub const PING: &str = "ping";
pub const HEALTH: &str = "health";
pub const DIAGNOSTICS: &str = "diagnostics";
pub const GITHUB_STATUS: &str = "github.status";
pub const AUDIT_EVENTS: &str = "audit.events";
pub const CONFIG: &str = "config.get";
pub const DAEMON_STOP: &str = "daemon.stop";
pub const BRIDGE_RECONFIGURE: &str = "bridge.reconfigure";
pub const DAEMON_LOG_LEVEL: &str = "daemon.log_level";
pub const DAEMON_SET_LOG_LEVEL: &str = "daemon.set_log_level";
pub const PROJECTS: &str = "projects";
pub const SESSIONS: &str = "sessions";
pub const RUNTIME_SESSION_RESOLVE: &str = "runtime_session.resolve";
pub const RUNTIMES_PROBE: &str = "runtimes.probe";
pub const STREAM_SUBSCRIBE: &str = "stream.subscribe";
pub const STREAM_UNSUBSCRIBE: &str = "stream.unsubscribe";
pub const SESSION_DETAIL: &str = "session.detail";
pub const SESSION_TIMELINE: &str = "session.timeline";
pub const SESSION_SUBSCRIBE: &str = "session.subscribe";
pub const SESSION_UNSUBSCRIBE: &str = "session.unsubscribe";
pub const SESSION_START: &str = "session.start";
pub const SESSION_ADOPT: &str = "session.adopt";
pub const SESSION_DELETE: &str = "session.delete";
pub const SESSION_JOIN: &str = "session.join";
pub const SESSION_RUNTIME_SESSION: &str = "session.runtime_session";
pub const SESSION_TITLE: &str = "session.title";
pub const SESSION_END: &str = "session.end";
pub const SESSION_ARCHIVE: &str = "session.archive";
pub const SESSION_LEAVE: &str = "session.leave";
pub const SESSION_OBSERVE: &str = "session.observe";
pub const TASK_CREATE: &str = "task.create";
pub const TASK_DELETE: &str = "task.delete";
pub const TASK_ASSIGN: &str = "task.assign";
pub const TASK_DROP: &str = "task.drop";
pub const TASK_QUEUE_POLICY: &str = "task.queue_policy";
pub const TASK_UPDATE: &str = "task.update";
pub const TASK_CHECKPOINT: &str = "task.checkpoint";
pub const TASK_SUBMIT_FOR_REVIEW: &str = "task.submit_for_review";
pub const TASK_CLAIM_REVIEW: &str = "task.claim_review";
pub const TASK_SUBMIT_REVIEW: &str = "task.submit_review";
pub const TASK_RESPOND_REVIEW: &str = "task.respond_review";
pub const TASK_ARBITRATE: &str = "task.arbitrate";
pub const IMPROVER_APPLY: &str = "improver.apply";
pub const TASK_BOARD_CREATE: &str = "task_board.create";
pub const TASK_BOARD_CAPABILITIES: &str = "task_board.capabilities";
pub const TASK_BOARD_LIST: &str = "task_board.list";
pub const TASK_BOARD_GET: &str = "task_board.get";
pub const TASK_BOARD_UPDATE: &str = "task_board.update";
pub const TASK_BOARD_DELETE: &str = "task_board.delete";
pub const TASK_BOARD_PLAN_BEGIN: &str = "task_board.plan_begin";
pub const TASK_BOARD_PLAN_SUBMIT: &str = "task_board.plan_submit";
pub const TASK_BOARD_PLAN_APPROVE: &str = "task_board.plan_approve";
pub const TASK_BOARD_PLAN_REVOKE: &str = "task_board.plan_revoke";
pub const TASK_BOARD_SYNC: &str = "task_board.sync";
pub const TASK_BOARD_DISPATCH: &str = "task_board.dispatch";
pub const TASK_BOARD_DISPATCH_DELIVER: &str = "task_board.dispatch_deliver";
pub const TASK_BOARD_DISPATCH_PICK: &str = "task_board.dispatch_pick";
pub const TASK_BOARD_EVALUATE: &str = "task_board.evaluate";
pub const TASK_BOARD_AUDIT: &str = "task_board.audit";
pub const TASK_BOARD_PROJECTS: &str = "task_board.projects";
pub const TASK_BOARD_MACHINES: &str = "task_board.machines";
pub const TASK_BOARD_HOST_LOCAL: &str = "task_board.host_local";
pub const TASK_BOARD_HOST_LIST: &str = "task_board.host_list";
pub const TASK_BOARD_HOST_SET_PROJECT_TYPES: &str = "task_board.host_set_project_types";
pub const TASK_BOARD_ORCHESTRATOR_STATUS: &str = "task_board.orchestrator_status";
pub const TASK_BOARD_ORCHESTRATOR_START: &str = "task_board.orchestrator_start";
pub const TASK_BOARD_ORCHESTRATOR_STOP: &str = "task_board.orchestrator_stop";
pub const TASK_BOARD_ORCHESTRATOR_RUN_ONCE: &str = "task_board.orchestrator_run_once";
pub const TASK_BOARD_ORCHESTRATOR_RUNS: &str = "task_board.orchestrator_runs";
pub const TASK_BOARD_ORCHESTRATOR_RUN_DETAIL: &str = "task_board.orchestrator_run_detail";
pub const TASK_BOARD_ORCHESTRATOR_METRICS: &str = "task_board.orchestrator_metrics";
pub const TASK_BOARD_ORCHESTRATOR_SETTINGS_GET: &str = "task_board.orchestrator_settings_get";
pub const TASK_BOARD_ORCHESTRATOR_SETTINGS_UPDATE: &str = "task_board.orchestrator_settings_update";
pub const TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG_GET: &str =
    "task_board.orchestrator_runtime_config_get";
pub const TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG_UPDATE: &str =
    "task_board.orchestrator_runtime_config_update";
pub const TASK_BOARD_ORCHESTRATOR_GITHUB_TOKENS_SYNC: &str =
    "task_board.orchestrator_github_tokens_sync";
pub const TASK_BOARD_ORCHESTRATOR_TODOIST_TOKEN_SYNC: &str =
    "task_board.orchestrator_todoist_token_sync";
pub const TASK_BOARD_ORCHESTRATOR_OPENROUTER_TOKEN_SYNC: &str =
    "task_board.orchestrator_openrouter_token_sync";
pub const TASK_BOARD_GIT_IDENTITY_DEFAULTS: &str = "task_board.git_identity_defaults";
pub const TASK_BOARD_GIT_SIGNING_VERIFY: &str = "task_board.git_signing_verify";
pub const TASK_BOARD_GIT_RUNTIME_KEY_MATERIAL_SYNC: &str =
    "task_board.git_runtime_key_material_sync";
pub const TASK_BOARD_GIT_RUNTIME_SECRET_HANDOFF_PREPARE: &str =
    "task_board.git_runtime_secret_handoff_prepare";
pub const TASK_BOARD_GIT_RUNTIME_SECRET_HANDOFF_ACK: &str =
    "task_board.git_runtime_secret_handoff_ack";
pub const POLICY_CANVAS_WORKSPACE_GET: &str = "policy_canvas.workspace_get";
pub const POLICY_CANVAS_CREATE: &str = "policy_canvas.create";
pub const POLICY_CANVAS_DUPLICATE: &str = "policy_canvas.duplicate";
pub const POLICY_CANVAS_RENAME: &str = "policy_canvas.rename";
pub const POLICY_CANVAS_SET_ACTIVE: &str = "policy_canvas.set_active";
pub const POLICY_CANVAS_DELETE: &str = "policy_canvas.delete";
pub const POLICY_CANVAS_SET_GLOBAL_ENFORCEMENT: &str = "policy_canvas.set_global_enforcement";
pub const POLICY_CANVAS_SET_SPAWN_REQUIRES_LIVE_POLICY: &str =
    "policy_canvas.set_spawn_requires_live_policy";
pub const POLICY_CANVAS_SET_SPAWN_KILL_SWITCH: &str = "policy_canvas.set_spawn_kill_switch";
pub const POLICY_APPROVAL_GRANTS_LIST: &str = "policy_canvas.approval_grants_list";
pub const POLICY_APPROVAL_GRANT_RESOLVE: &str = "policy_canvas.approval_grant_resolve";
pub const POLICY_APPROVAL_GRANT_REVOKE: &str = "policy_canvas.approval_grant_revoke";
pub const POLICY_PIPELINE_GET: &str = "policy_pipeline.get";
pub const POLICY_PIPELINE_SAVE_DRAFT: &str = "policy_pipeline.save_draft";
pub const POLICY_PIPELINE_SIMULATE: &str = "policy_pipeline.simulate";
pub const POLICY_PIPELINE_PROMOTE: &str = "policy_pipeline.promote";
pub const POLICY_PIPELINE_MAKE_LIVE: &str = "policy_pipeline.make_live";
pub const POLICY_PIPELINE_GO_LIVE_DIFF: &str = "policy_pipeline.go_live_diff";
pub const POLICY_PIPELINE_REPLAY: &str = "policy_pipeline.replay";
pub const POLICY_PIPELINE_AUDIT: &str = "policy_pipeline.audit";
pub const POLICY_CANVAS_EXPORT: &str = "policy_canvas.export";
pub const POLICY_CANVAS_IMPORT: &str = "policy_canvas.import";
pub const POLICY_SCENARIO_CREATE: &str = "policy_scenario.create";
pub const POLICY_SCENARIO_UPDATE: &str = "policy_scenario.update";
pub const POLICY_SCENARIO_DELETE: &str = "policy_scenario.delete";
pub const POLICY_SCENARIO_RESET: &str = "policy_scenario.reset";
pub const REVIEWS_REPOSITORY_CATALOG: &str = "reviews.repository_catalog";
pub const REVIEWS_CAPABILITIES: &str = "reviews.capabilities";
pub const REVIEWS_QUERY: &str = "reviews.query";
pub const REVIEWS_PULL_REQUEST_RESOLVE: &str = "reviews.pull_requests_resolve";
pub const REVIEWS_ACTION_PREVIEW: &str = "reviews.action_preview";
pub const REVIEWS_POLICY_PREVIEW: &str = "reviews.policy_preview";
pub const REVIEWS_POLICY_START: &str = "reviews.policy_start";
pub const REVIEWS_POLICY_STATUS: &str = "reviews.policy_status";
pub const REVIEWS_POLICY_HISTORY: &str = "reviews.policy_history";
pub const REVIEWS_APPROVE: &str = "reviews.approve";
pub const REVIEWS_MERGE: &str = "reviews.merge";
pub const REVIEWS_RERUN_CHECKS: &str = "reviews.rerun_checks";
pub const REVIEWS_ADD_LABEL: &str = "reviews.add_label";
pub const REVIEWS_AUTO: &str = "reviews.auto";
pub const REVIEWS_REQUEST_REVIEW: &str = "reviews.request_review";
pub const REVIEWS_CLEAR_CACHE: &str = "reviews.clear_cache";
pub const REVIEWS_REFRESH: &str = "reviews.refresh";
pub const REVIEWS_BODY: &str = "reviews.body";
pub const REVIEWS_BODY_UPDATE: &str = "reviews.body_update";
pub const REVIEWS_COMMENT: &str = "reviews.comment";
pub const REVIEWS_FILES_LIST: &str = "reviews.files_list";
pub const REVIEWS_FILES_PATCH: &str = "reviews.files_patch";
pub const REVIEWS_FILES_PREVIEW: &str = "reviews.files_preview";
pub const REVIEWS_FILES_VIEWED: &str = "reviews.files_viewed";
pub const REVIEWS_FILES_BLOB: &str = "reviews.files_blob";
pub const REVIEWS_FILES_COMMENT: &str = "reviews.files_comment";
pub const REVIEWS_FILES_LOCAL_CLONES_LIST: &str = "reviews.files_local_clones_list";
pub const REVIEWS_FILES_LOCAL_CLONES_DELETE: &str = "reviews.files_local_clones_delete";
pub const REVIEWS_AVATAR: &str = "reviews.avatar";
pub const REVIEWS_TIMELINE: &str = "reviews.timeline";
pub const REVIEWS_REVIEW_THREADS_RESOLVE: &str = "reviews.review_threads_resolve";
pub const AGENT_CHANGE_ROLE: &str = "agent.change_role";
pub const AGENT_REMOVE: &str = "agent.remove";
pub const LEADER_TRANSFER: &str = "leader.transfer";
pub const SESSION_MANAGED_AGENTS: &str = "session.managed_agents";
pub const MANAGED_AGENT_START_TERMINAL: &str = "managed_agent.start_terminal";
pub const MANAGED_AGENT_START_CODEX: &str = "managed_agent.start_codex";
pub const MANAGED_AGENT_START_ACP: &str = "managed_agent.start_acp";
pub const MANAGED_AGENT_DETAIL: &str = "managed_agent.detail";
pub const MANAGED_AGENT_INPUT: &str = "managed_agent.input";
pub const MANAGED_AGENT_RESIZE: &str = "managed_agent.resize";
pub const MANAGED_AGENT_STOP: &str = "managed_agent.stop";
pub const MANAGED_AGENT_READY: &str = "managed_agent.ready";
pub const MANAGED_AGENT_STEER_CODEX: &str = "managed_agent.steer_codex";
pub const MANAGED_AGENT_INTERRUPT_CODEX: &str = "managed_agent.interrupt_codex";
pub const MANAGED_AGENT_RESOLVE_CODEX_APPROVAL: &str = "managed_agent.resolve_codex_approval";
pub const MANAGED_AGENT_RESOLVE_ACP_PERMISSION: &str = "managed_agent.resolve_acp_permission";
pub const MANAGED_AGENT_STOP_ACP: &str = "managed_agent.stop_acp";
pub const MANAGED_AGENT_PROMPT_ACP: &str = "managed_agent.prompt_acp";
pub const MANAGED_AGENTS_CODEX_INSPECT: &str = "managed_agent.codex_inspect";
pub const MANAGED_AGENTS_CODEX_TRANSCRIPT: &str = "managed_agent.codex_transcript";
pub const MANAGED_AGENTS_ACP_INSPECT: &str = "managed_agent.acp_inspect";
pub const MANAGED_AGENTS_ACP_TRANSCRIPT: &str = "managed_agent.acp_transcript";
pub const OPENROUTER_LIST_MODELS: &str = "openrouter.list_models";
pub const SIGNAL_SEND: &str = "signal.send";
pub const SIGNAL_CANCEL: &str = "signal.cancel";
pub const SIGNAL_ACK: &str = "signal.ack";
pub const VOICE_START_SESSION: &str = "voice.start_session";
pub const VOICE_APPEND_AUDIO: &str = "voice.append_audio";
pub const VOICE_APPEND_TRANSCRIPT: &str = "voice.append_transcript";
pub const VOICE_FINISH_SESSION: &str = "voice.finish_session";

// Keep this slice in sync with every public websocket method constant above.
// Remote scope coverage iterates this list directly.
pub const ALL: &[&str] = &[
    PING,
    HEALTH,
    DIAGNOSTICS,
    GITHUB_STATUS,
    AUDIT_EVENTS,
    CONFIG,
    DAEMON_STOP,
    BRIDGE_RECONFIGURE,
    DAEMON_LOG_LEVEL,
    DAEMON_SET_LOG_LEVEL,
    PROJECTS,
    SESSIONS,
    RUNTIME_SESSION_RESOLVE,
    RUNTIMES_PROBE,
    STREAM_SUBSCRIBE,
    STREAM_UNSUBSCRIBE,
    SESSION_DETAIL,
    SESSION_TIMELINE,
    SESSION_SUBSCRIBE,
    SESSION_UNSUBSCRIBE,
    SESSION_START,
    SESSION_ADOPT,
    SESSION_DELETE,
    SESSION_JOIN,
    SESSION_RUNTIME_SESSION,
    SESSION_TITLE,
    SESSION_END,
    SESSION_ARCHIVE,
    SESSION_LEAVE,
    SESSION_OBSERVE,
    TASK_CREATE,
    TASK_DELETE,
    TASK_ASSIGN,
    TASK_DROP,
    TASK_QUEUE_POLICY,
    TASK_UPDATE,
    TASK_CHECKPOINT,
    TASK_SUBMIT_FOR_REVIEW,
    TASK_CLAIM_REVIEW,
    TASK_SUBMIT_REVIEW,
    TASK_RESPOND_REVIEW,
    TASK_ARBITRATE,
    IMPROVER_APPLY,
    TASK_BOARD_CREATE,
    TASK_BOARD_CAPABILITIES,
    TASK_BOARD_LIST,
    TASK_BOARD_GET,
    TASK_BOARD_UPDATE,
    TASK_BOARD_DELETE,
    TASK_BOARD_PLAN_BEGIN,
    TASK_BOARD_PLAN_SUBMIT,
    TASK_BOARD_PLAN_APPROVE,
    TASK_BOARD_PLAN_REVOKE,
    TASK_BOARD_SYNC,
    TASK_BOARD_DISPATCH,
    TASK_BOARD_DISPATCH_DELIVER,
    TASK_BOARD_DISPATCH_PICK,
    TASK_BOARD_EVALUATE,
    TASK_BOARD_AUDIT,
    TASK_BOARD_PROJECTS,
    TASK_BOARD_MACHINES,
    TASK_BOARD_HOST_LOCAL,
    TASK_BOARD_HOST_LIST,
    TASK_BOARD_HOST_SET_PROJECT_TYPES,
    TASK_BOARD_ORCHESTRATOR_STATUS,
    TASK_BOARD_ORCHESTRATOR_START,
    TASK_BOARD_ORCHESTRATOR_STOP,
    TASK_BOARD_ORCHESTRATOR_RUN_ONCE,
    TASK_BOARD_ORCHESTRATOR_RUNS,
    TASK_BOARD_ORCHESTRATOR_RUN_DETAIL,
    TASK_BOARD_ORCHESTRATOR_METRICS,
    TASK_BOARD_ORCHESTRATOR_SETTINGS_GET,
    TASK_BOARD_ORCHESTRATOR_SETTINGS_UPDATE,
    TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG_GET,
    TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG_UPDATE,
    TASK_BOARD_ORCHESTRATOR_GITHUB_TOKENS_SYNC,
    TASK_BOARD_ORCHESTRATOR_TODOIST_TOKEN_SYNC,
    TASK_BOARD_ORCHESTRATOR_OPENROUTER_TOKEN_SYNC,
    TASK_BOARD_GIT_IDENTITY_DEFAULTS,
    TASK_BOARD_GIT_SIGNING_VERIFY,
    TASK_BOARD_GIT_RUNTIME_KEY_MATERIAL_SYNC,
    TASK_BOARD_GIT_RUNTIME_SECRET_HANDOFF_PREPARE,
    TASK_BOARD_GIT_RUNTIME_SECRET_HANDOFF_ACK,
    POLICY_CANVAS_WORKSPACE_GET,
    POLICY_CANVAS_CREATE,
    POLICY_CANVAS_DUPLICATE,
    POLICY_CANVAS_RENAME,
    POLICY_CANVAS_SET_ACTIVE,
    POLICY_CANVAS_DELETE,
    POLICY_CANVAS_SET_GLOBAL_ENFORCEMENT,
    POLICY_CANVAS_SET_SPAWN_REQUIRES_LIVE_POLICY,
    POLICY_CANVAS_SET_SPAWN_KILL_SWITCH,
    POLICY_APPROVAL_GRANTS_LIST,
    POLICY_APPROVAL_GRANT_RESOLVE,
    POLICY_APPROVAL_GRANT_REVOKE,
    POLICY_PIPELINE_GET,
    POLICY_PIPELINE_SAVE_DRAFT,
    POLICY_PIPELINE_SIMULATE,
    POLICY_PIPELINE_PROMOTE,
    POLICY_PIPELINE_MAKE_LIVE,
    POLICY_PIPELINE_GO_LIVE_DIFF,
    POLICY_PIPELINE_REPLAY,
    POLICY_PIPELINE_AUDIT,
    POLICY_CANVAS_EXPORT,
    POLICY_CANVAS_IMPORT,
    POLICY_SCENARIO_CREATE,
    POLICY_SCENARIO_UPDATE,
    POLICY_SCENARIO_DELETE,
    POLICY_SCENARIO_RESET,
    REVIEWS_REPOSITORY_CATALOG,
    REVIEWS_CAPABILITIES,
    REVIEWS_QUERY,
    REVIEWS_PULL_REQUEST_RESOLVE,
    REVIEWS_ACTION_PREVIEW,
    REVIEWS_POLICY_PREVIEW,
    REVIEWS_POLICY_START,
    REVIEWS_POLICY_STATUS,
    REVIEWS_POLICY_HISTORY,
    REVIEWS_APPROVE,
    REVIEWS_MERGE,
    REVIEWS_RERUN_CHECKS,
    REVIEWS_ADD_LABEL,
    REVIEWS_AUTO,
    REVIEWS_REQUEST_REVIEW,
    REVIEWS_CLEAR_CACHE,
    REVIEWS_REFRESH,
    REVIEWS_BODY,
    REVIEWS_BODY_UPDATE,
    REVIEWS_COMMENT,
    REVIEWS_FILES_LIST,
    REVIEWS_FILES_PATCH,
    REVIEWS_FILES_PREVIEW,
    REVIEWS_FILES_VIEWED,
    REVIEWS_FILES_BLOB,
    REVIEWS_FILES_COMMENT,
    REVIEWS_FILES_LOCAL_CLONES_LIST,
    REVIEWS_FILES_LOCAL_CLONES_DELETE,
    REVIEWS_AVATAR,
    REVIEWS_TIMELINE,
    REVIEWS_REVIEW_THREADS_RESOLVE,
    AGENT_CHANGE_ROLE,
    AGENT_REMOVE,
    LEADER_TRANSFER,
    SESSION_MANAGED_AGENTS,
    MANAGED_AGENT_START_TERMINAL,
    MANAGED_AGENT_START_CODEX,
    MANAGED_AGENT_START_ACP,
    MANAGED_AGENT_DETAIL,
    MANAGED_AGENT_INPUT,
    MANAGED_AGENT_RESIZE,
    MANAGED_AGENT_STOP,
    MANAGED_AGENT_READY,
    MANAGED_AGENT_STEER_CODEX,
    MANAGED_AGENT_INTERRUPT_CODEX,
    MANAGED_AGENT_RESOLVE_CODEX_APPROVAL,
    MANAGED_AGENT_RESOLVE_ACP_PERMISSION,
    MANAGED_AGENT_STOP_ACP,
    MANAGED_AGENT_PROMPT_ACP,
    MANAGED_AGENTS_CODEX_INSPECT,
    MANAGED_AGENTS_CODEX_TRANSCRIPT,
    MANAGED_AGENTS_ACP_INSPECT,
    MANAGED_AGENTS_ACP_TRANSCRIPT,
    OPENROUTER_LIST_MODELS,
    SIGNAL_SEND,
    SIGNAL_CANCEL,
    SIGNAL_ACK,
    VOICE_START_SESSION,
    VOICE_APPEND_AUDIO,
    VOICE_APPEND_TRANSCRIPT,
    VOICE_FINISH_SESSION,
];
