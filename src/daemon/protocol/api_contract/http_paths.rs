pub const HEALTH: &str = "/v1/health";
pub const READY: &str = "/v1/ready";
pub const DIAGNOSTICS: &str = "/v1/diagnostics";
pub const DAEMON_STOP: &str = "/v1/daemon/stop";
pub const BRIDGE_RECONFIGURE: &str = "/v1/bridge/reconfigure";
pub const DAEMON_LOG_LEVEL: &str = "/v1/daemon/log-level";
pub const PROJECTS: &str = "/v1/projects";
pub const RUNTIME_SESSION_RESOLVE: &str = "/v1/runtime-sessions/resolve";
pub const RUNTIMES_PROBE: &str = "/v1/runtimes/probe";
pub const WS: &str = "/v1/ws";
pub const STREAM: &str = "/v1/stream";
pub const SESSIONS: &str = "/v1/sessions";
pub const SESSIONS_ADOPT: &str = "/v1/sessions/adopt";
pub const SESSION_DETAIL: &str = "/v1/sessions/{session_id}";
pub const SESSION_TIMELINE: &str = "/v1/sessions/{session_id}/timeline";
pub const SESSION_STREAM: &str = "/v1/sessions/{session_id}/stream";
pub const SESSION_JOIN: &str = "/v1/sessions/{session_id}/join";
pub const SESSION_RUNTIME_SESSION: &str = "/v1/sessions/{session_id}/runtime-session";
pub const SESSION_TITLE: &str = "/v1/sessions/{session_id}/title";
pub const SESSION_END: &str = "/v1/sessions/{session_id}/end";
pub const SESSION_LEAVE: &str = "/v1/sessions/{session_id}/leave";
pub const SESSION_OBSERVE: &str = "/v1/sessions/{session_id}/observe";
pub const SESSION_TASK_CREATE: &str = "/v1/sessions/{session_id}/task";
pub const SESSION_TASK_ASSIGN: &str = "/v1/sessions/{session_id}/tasks/{task_id}/assign";
pub const SESSION_TASK_DROP: &str = "/v1/sessions/{session_id}/tasks/{task_id}/drop";
pub const SESSION_TASK_QUEUE_POLICY: &str =
    "/v1/sessions/{session_id}/tasks/{task_id}/queue-policy";
pub const SESSION_TASK_UPDATE: &str = "/v1/sessions/{session_id}/tasks/{task_id}/status";
pub const SESSION_TASK_CHECKPOINT: &str = "/v1/sessions/{session_id}/tasks/{task_id}/checkpoint";
pub const SESSION_TASK_SUBMIT_FOR_REVIEW: &str =
    "/v1/sessions/{session_id}/tasks/{task_id}/submit-for-review";
pub const SESSION_TASK_CLAIM_REVIEW: &str =
    "/v1/sessions/{session_id}/tasks/{task_id}/claim-review";
pub const SESSION_TASK_SUBMIT_REVIEW: &str =
    "/v1/sessions/{session_id}/tasks/{task_id}/submit-review";
pub const SESSION_TASK_RESPOND_REVIEW: &str =
    "/v1/sessions/{session_id}/tasks/{task_id}/respond-review";
pub const SESSION_TASK_ARBITRATE: &str = "/v1/sessions/{session_id}/tasks/{task_id}/arbitrate";
pub const SESSION_IMPROVER_APPLY: &str = "/v1/sessions/{session_id}/improver/apply";
pub const SESSION_AGENT_ROLE: &str = "/v1/sessions/{session_id}/agents/{agent_id}/role";
pub const SESSION_AGENT_REMOVE: &str = "/v1/sessions/{session_id}/agents/{agent_id}/remove";
pub const SESSION_LEADER_TRANSFER: &str = "/v1/sessions/{session_id}/leader";
pub const SESSION_MANAGED_AGENTS: &str = "/v1/sessions/{session_id}/managed-agents";
pub const SESSION_MANAGED_AGENTS_TERMINAL: &str =
    "/v1/sessions/{session_id}/managed-agents/terminal";
pub const SESSION_MANAGED_AGENTS_CODEX: &str = "/v1/sessions/{session_id}/managed-agents/codex";
pub const SESSION_MANAGED_AGENTS_ACP: &str = "/v1/sessions/{session_id}/managed-agents/acp";
pub const MANAGED_AGENT_DETAIL: &str = "/v1/managed-agents/{agent_id}";
pub const MANAGED_AGENT_INPUT: &str = "/v1/managed-agents/{agent_id}/input";
pub const MANAGED_AGENT_RESIZE: &str = "/v1/managed-agents/{agent_id}/resize";
pub const MANAGED_AGENT_STOP: &str = "/v1/managed-agents/{agent_id}/stop";
pub const MANAGED_AGENT_READY: &str = "/v1/managed-agents/{agent_id}/ready";
pub const MANAGED_AGENT_ATTACH: &str = "/v1/managed-agents/{agent_id}/attach";
pub const MANAGED_AGENT_STEER: &str = "/v1/managed-agents/{agent_id}/steer";
pub const MANAGED_AGENT_INTERRUPT: &str = "/v1/managed-agents/{agent_id}/interrupt";
pub const MANAGED_AGENT_APPROVAL: &str = "/v1/managed-agents/{agent_id}/approvals/{approval_id}";
pub const MANAGED_AGENT_ACP_PERMISSION: &str =
    "/v1/managed-agents/{agent_id}/permission-batches/{batch_id}";
pub const MANAGED_AGENT_DELETE: &str = "/v1/managed-agents/{agent_id}";
pub const MANAGED_AGENTS_ACP_INSPECT: &str = "/v1/managed-agents/acp/inspect";
pub const SESSION_SIGNAL_SEND: &str = "/v1/sessions/{session_id}/signal";
pub const SESSION_SIGNAL_CANCEL: &str = "/v1/sessions/{session_id}/signal-cancel";
pub const SESSION_SIGNAL_ACK: &str = "/v1/sessions/{session_id}/signal-ack";
pub const SESSION_VOICE_START: &str = "/v1/sessions/{session_id}/voice-sessions";
pub const VOICE_AUDIO_APPEND: &str = "/v1/voice-sessions/{voice_session_id}/audio";
pub const VOICE_TRANSCRIPT_APPEND: &str = "/v1/voice-sessions/{voice_session_id}/transcript";
pub const VOICE_FINISH: &str = "/v1/voice-sessions/{voice_session_id}/finish";
