use std::error::Error;
use std::fmt;

use super::protocol::{HttpApiRouteContract, http_paths, ws_methods};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RemoteRole {
    Admin,
    Operator,
    Viewer,
    ExecutionCoordinator,
}

impl RemoteRole {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Admin => "admin",
            Self::Operator => "operator",
            Self::Viewer => "viewer",
            Self::ExecutionCoordinator => "execution_coordinator",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RemoteAccessScope {
    Read,
    Write,
    Admin,
    Execute,
}

impl RemoteAccessScope {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Read => "read",
            Self::Write => "write",
            Self::Admin => "admin",
            Self::Execute => "execute",
        }
    }
}

const READ_SCOPES: &[RemoteAccessScope] = &[RemoteAccessScope::Read];
const WRITE_SCOPES: &[RemoteAccessScope] = &[RemoteAccessScope::Write];
const ADMIN_SCOPES: &[RemoteAccessScope] = &[RemoteAccessScope::Admin];
const EXECUTION_SCOPES: &[RemoteAccessScope] = &[RemoteAccessScope::Execute];
const ADMIN_ROLE_SCOPES: &[RemoteAccessScope] = &[
    RemoteAccessScope::Read,
    RemoteAccessScope::Write,
    RemoteAccessScope::Admin,
];
const OPERATOR_ROLE_SCOPES: &[RemoteAccessScope] =
    &[RemoteAccessScope::Read, RemoteAccessScope::Write];

#[must_use]
pub const fn scopes_for_role(role: RemoteRole) -> &'static [RemoteAccessScope] {
    match role {
        RemoteRole::Admin => ADMIN_ROLE_SCOPES,
        RemoteRole::Operator => OPERATOR_ROLE_SCOPES,
        RemoteRole::Viewer => READ_SCOPES,
        RemoteRole::ExecutionCoordinator => EXECUTION_SCOPES,
    }
}

#[must_use]
pub fn remote_http_scopes(route: &HttpApiRouteContract) -> Option<&'static [RemoteAccessScope]> {
    match route.path {
        http_paths::READY | http_paths::WS | http_paths::STREAM | http_paths::SESSION_STREAM => {
            Some(READ_SCOPES)
        }
        http_paths::REMOTE_PAIR_CLAIM
        | http_paths::REMOTE_PAIR_STATUS
        | http_paths::REMOTE_CLIENT_SELF_REVOKE
        | http_paths::MANAGED_AGENT_ACP_SESSIONS
        | http_paths::POLICIES_DUMP => Some(READ_SCOPES),
        http_paths::DAEMON_TELEMETRY
        | http_paths::MANAGED_AGENT_ATTACH
        | http_paths::MANAGED_AGENT_ACP_LOGOUT
        | http_paths::MANAGED_AGENT_ACP_SESSION_DELETE
        | http_paths::MANAGED_AGENT_ACP_SESSION_CLOSE
        | http_paths::POLICIES_IMPORT => Some(WRITE_SCOPES),
        _ => route.parity.ws_method().and_then(remote_ws_scopes),
    }
}

#[must_use]
pub fn remote_ws_scopes(method: &str) -> Option<&'static [RemoteAccessScope]> {
    if READ_WS_METHODS.contains(&method) {
        Some(READ_SCOPES)
    } else if WRITE_WS_METHODS.contains(&method) {
        Some(WRITE_SCOPES)
    } else if ADMIN_WS_METHODS.contains(&method) {
        Some(ADMIN_SCOPES)
    } else {
        None
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteAcmeChallenge {
    TlsAlpn,
    Http,
    Dns,
}

impl RemoteAcmeChallenge {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::TlsAlpn => "tls-alpn",
            Self::Http => "http",
            Self::Dns => "dns",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteDnsProvider {
    Aftermarket,
    Cloudflare,
    Route53,
    Exec,
}

impl RemoteDnsProvider {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Aftermarket => "aftermarket",
            Self::Cloudflare => "cloudflare",
            Self::Route53 => "route53",
            Self::Exec => "exec",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteDaemonServeConfig {
    pub domain: String,
    pub host: String,
    pub https_port: u16,
    pub http_port: u16,
    pub acme_email: String,
    pub acme_challenge: RemoteAcmeChallenge,
    pub acme_dns_provider: Option<RemoteDnsProvider>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RemoteDaemonConfigError {
    MissingDomain,
    MissingHost,
    MissingAcmeEmail,
    MissingHttpsPort,
    MissingHttpPort,
    MissingDnsProvider,
    UnexpectedDnsProvider,
}

impl fmt::Display for RemoteDaemonConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingDomain => write!(f, "remote daemon domain is required"),
            Self::MissingHost => write!(f, "remote daemon bind host is required"),
            Self::MissingAcmeEmail => write!(f, "remote daemon ACME email is required"),
            Self::MissingHttpsPort => write!(f, "remote daemon HTTPS port must be non-zero"),
            Self::MissingHttpPort => write!(f, "remote daemon HTTP-01 port must be non-zero"),
            Self::MissingDnsProvider => {
                write!(f, "remote daemon DNS-01 challenge requires a DNS provider")
            }
            Self::UnexpectedDnsProvider => {
                write!(
                    f,
                    "remote daemon DNS provider is only valid with DNS-01 challenge"
                )
            }
        }
    }
}

impl Error for RemoteDaemonConfigError {}

/// Validate the static remote serve contract before later phases start listeners.
///
/// # Errors
/// Returns [`RemoteDaemonConfigError`] when required TLS or ACME identity
/// settings are missing.
pub fn validate_remote_serve_config(
    config: &RemoteDaemonServeConfig,
) -> Result<(), RemoteDaemonConfigError> {
    if config.domain.trim().is_empty() {
        return Err(RemoteDaemonConfigError::MissingDomain);
    }
    if config.host.trim().is_empty() {
        return Err(RemoteDaemonConfigError::MissingHost);
    }
    if config.acme_email.trim().is_empty() {
        return Err(RemoteDaemonConfigError::MissingAcmeEmail);
    }
    if config.https_port == 0 {
        return Err(RemoteDaemonConfigError::MissingHttpsPort);
    }
    if !matches!(config.acme_challenge, RemoteAcmeChallenge::Dns)
        && config.acme_dns_provider.is_some()
    {
        return Err(RemoteDaemonConfigError::UnexpectedDnsProvider);
    }
    match config.acme_challenge {
        RemoteAcmeChallenge::Http if config.http_port == 0 => {
            Err(RemoteDaemonConfigError::MissingHttpPort)
        }
        RemoteAcmeChallenge::Dns if config.acme_dns_provider.is_none() => {
            Err(RemoteDaemonConfigError::MissingDnsProvider)
        }
        RemoteAcmeChallenge::TlsAlpn | RemoteAcmeChallenge::Http | RemoteAcmeChallenge::Dns => {
            Ok(())
        }
    }
}

const READ_WS_METHODS: &[&str] = &[
    ws_methods::PING,
    ws_methods::HEALTH,
    ws_methods::DIAGNOSTICS,
    ws_methods::GITHUB_STATUS,
    ws_methods::AUDIT_EVENTS,
    ws_methods::CONFIG,
    ws_methods::DAEMON_LOG_LEVEL,
    ws_methods::PROJECTS,
    ws_methods::SESSIONS,
    ws_methods::RUNTIME_SESSION_RESOLVE,
    ws_methods::RUNTIMES_PROBE,
    ws_methods::STREAM_SUBSCRIBE,
    ws_methods::STREAM_UNSUBSCRIBE,
    ws_methods::SESSION_DETAIL,
    ws_methods::SESSION_TIMELINE,
    ws_methods::SESSION_SUBSCRIBE,
    ws_methods::SESSION_UNSUBSCRIBE,
    ws_methods::SESSION_MANAGED_AGENTS,
    ws_methods::MANAGED_AGENT_DETAIL,
    ws_methods::MANAGED_AGENTS_CODEX_INSPECT,
    ws_methods::MANAGED_AGENTS_CODEX_TRANSCRIPT,
    ws_methods::MANAGED_AGENTS_ACP_INSPECT,
    ws_methods::MANAGED_AGENTS_ACP_TRANSCRIPT,
    ws_methods::OPENROUTER_LIST_MODELS,
    ws_methods::TASK_BOARD_CAPABILITIES,
    ws_methods::TASK_BOARD_LIST,
    ws_methods::TASK_BOARD_GET,
    ws_methods::TASK_BOARD_POSITION_GET,
    ws_methods::TASK_BOARD_DISPATCH_PICK,
    ws_methods::TASK_BOARD_AUDIT,
    ws_methods::TASK_BOARD_PROJECTS,
    ws_methods::TASK_BOARD_MACHINES,
    ws_methods::TASK_BOARD_HOST_LOCAL,
    ws_methods::TASK_BOARD_HOST_LIST,
    ws_methods::TASK_BOARD_ORCHESTRATOR_STATUS,
    ws_methods::TASK_BOARD_ORCHESTRATOR_RUNS,
    ws_methods::TASK_BOARD_ORCHESTRATOR_METRICS,
    ws_methods::TASK_BOARD_ORCHESTRATOR_SETTINGS_GET,
    ws_methods::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG_GET,
    ws_methods::TASK_BOARD_GIT_IDENTITY_DEFAULTS,
    ws_methods::POLICY_CANVAS_WORKSPACE_GET,
    ws_methods::POLICY_PIPELINE_GET,
    ws_methods::POLICY_PIPELINE_GO_LIVE_DIFF,
    ws_methods::POLICY_PIPELINE_AUDIT,
    ws_methods::POLICY_APPROVAL_GRANTS_LIST,
    ws_methods::POLICY_CANVAS_EXPORT,
    ws_methods::REVIEWS_REPOSITORY_CATALOG,
    ws_methods::REVIEWS_CAPABILITIES,
    ws_methods::REVIEWS_QUERY,
    ws_methods::REVIEWS_PULL_REQUEST_RESOLVE,
    ws_methods::REVIEWS_ACTION_PREVIEW,
    ws_methods::REVIEWS_POLICY_PREVIEW,
    ws_methods::REVIEWS_POLICY_STATUS,
    ws_methods::REVIEWS_POLICY_HISTORY,
    ws_methods::REVIEWS_FILES_LIST,
    ws_methods::REVIEWS_FILES_PATCH,
    ws_methods::REVIEWS_FILES_PREVIEW,
    ws_methods::REVIEWS_FILES_BLOB,
    ws_methods::REVIEWS_FILES_LOCAL_CLONES_LIST,
    ws_methods::REVIEWS_AVATAR,
    ws_methods::REVIEWS_TIMELINE,
];

const WRITE_WS_METHODS: &[&str] = &[
    ws_methods::SESSION_START,
    ws_methods::SESSION_ADOPT,
    ws_methods::SESSION_DELETE,
    ws_methods::SESSION_JOIN,
    ws_methods::SESSION_RUNTIME_SESSION,
    ws_methods::SESSION_TITLE,
    ws_methods::SESSION_END,
    ws_methods::SESSION_ARCHIVE,
    ws_methods::SESSION_LEAVE,
    ws_methods::SESSION_OBSERVE,
    ws_methods::TASK_CREATE,
    ws_methods::TASK_DELETE,
    ws_methods::TASK_ASSIGN,
    ws_methods::TASK_DROP,
    ws_methods::TASK_QUEUE_POLICY,
    ws_methods::TASK_UPDATE,
    ws_methods::TASK_CHECKPOINT,
    ws_methods::TASK_SUBMIT_FOR_REVIEW,
    ws_methods::TASK_CLAIM_REVIEW,
    ws_methods::TASK_SUBMIT_REVIEW,
    ws_methods::TASK_RESPOND_REVIEW,
    ws_methods::TASK_ARBITRATE,
    ws_methods::IMPROVER_APPLY,
    ws_methods::AGENT_CHANGE_ROLE,
    ws_methods::AGENT_REMOVE,
    ws_methods::LEADER_TRANSFER,
    ws_methods::MANAGED_AGENT_START_TERMINAL,
    ws_methods::MANAGED_AGENT_START_CODEX,
    ws_methods::MANAGED_AGENT_START_ACP,
    ws_methods::MANAGED_AGENT_INPUT,
    ws_methods::MANAGED_AGENT_RESIZE,
    ws_methods::MANAGED_AGENT_STOP,
    ws_methods::MANAGED_AGENT_READY,
    ws_methods::MANAGED_AGENT_STEER_CODEX,
    ws_methods::MANAGED_AGENT_INTERRUPT_CODEX,
    ws_methods::MANAGED_AGENT_RESOLVE_CODEX_APPROVAL,
    ws_methods::MANAGED_AGENT_RESOLVE_ACP_PERMISSION,
    ws_methods::MANAGED_AGENT_STOP_ACP,
    ws_methods::MANAGED_AGENT_PROMPT_ACP,
    ws_methods::SIGNAL_SEND,
    ws_methods::SIGNAL_CANCEL,
    ws_methods::SIGNAL_ACK,
    ws_methods::VOICE_START_SESSION,
    ws_methods::VOICE_APPEND_AUDIO,
    ws_methods::VOICE_APPEND_TRANSCRIPT,
    ws_methods::VOICE_FINISH_SESSION,
    ws_methods::TASK_BOARD_CREATE,
    ws_methods::TASK_BOARD_UPDATE,
    ws_methods::TASK_BOARD_POSITION_SET,
    ws_methods::TASK_BOARD_POSITION_RESET,
    ws_methods::TASK_BOARD_DELETE,
    ws_methods::TASK_BOARD_PLAN_BEGIN,
    ws_methods::TASK_BOARD_PLAN_SUBMIT,
    ws_methods::TASK_BOARD_PLAN_APPROVE,
    ws_methods::TASK_BOARD_PLAN_REVOKE,
    ws_methods::TASK_BOARD_SYNC,
    ws_methods::TASK_BOARD_DISPATCH,
    ws_methods::TASK_BOARD_DISPATCH_DELIVER,
    ws_methods::TASK_BOARD_EVALUATE,
    ws_methods::TASK_BOARD_HOST_SET_PROJECT_TYPES,
    ws_methods::TASK_BOARD_ORCHESTRATOR_START,
    ws_methods::TASK_BOARD_ORCHESTRATOR_STOP,
    ws_methods::TASK_BOARD_ORCHESTRATOR_RUN_ONCE,
    ws_methods::TASK_BOARD_ORCHESTRATOR_RUN_DETAIL,
    ws_methods::TASK_BOARD_ORCHESTRATOR_SETTINGS_UPDATE,
    ws_methods::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG_UPDATE,
    ws_methods::TASK_BOARD_GIT_SIGNING_VERIFY,
    ws_methods::POLICY_CANVAS_CREATE,
    ws_methods::POLICY_CANVAS_DUPLICATE,
    ws_methods::POLICY_CANVAS_RENAME,
    ws_methods::POLICY_CANVAS_SET_ACTIVE,
    ws_methods::POLICY_CANVAS_DELETE,
    ws_methods::POLICY_CANVAS_SET_GLOBAL_ENFORCEMENT,
    ws_methods::POLICY_CANVAS_SET_SPAWN_REQUIRES_LIVE_POLICY,
    ws_methods::POLICY_CANVAS_SET_SPAWN_KILL_SWITCH,
    ws_methods::POLICY_APPROVAL_GRANT_RESOLVE,
    ws_methods::POLICY_APPROVAL_GRANT_REVOKE,
    ws_methods::POLICY_PIPELINE_SAVE_DRAFT,
    ws_methods::POLICY_PIPELINE_SIMULATE,
    ws_methods::POLICY_PIPELINE_PROMOTE,
    ws_methods::POLICY_PIPELINE_MAKE_LIVE,
    ws_methods::POLICY_PIPELINE_REPLAY,
    ws_methods::POLICY_CANVAS_IMPORT,
    ws_methods::POLICY_SCENARIO_CREATE,
    ws_methods::POLICY_SCENARIO_UPDATE,
    ws_methods::POLICY_SCENARIO_DELETE,
    ws_methods::POLICY_SCENARIO_RESET,
    ws_methods::REVIEWS_POLICY_START,
    ws_methods::REVIEWS_APPROVE,
    ws_methods::REVIEWS_MERGE,
    ws_methods::REVIEWS_RERUN_CHECKS,
    ws_methods::REVIEWS_ADD_LABEL,
    ws_methods::REVIEWS_AUTO,
    ws_methods::REVIEWS_REQUEST_REVIEW,
    ws_methods::REVIEWS_CLEAR_CACHE,
    ws_methods::REVIEWS_REFRESH,
    ws_methods::REVIEWS_BODY,
    ws_methods::REVIEWS_BODY_UPDATE,
    ws_methods::REVIEWS_COMMENT,
    ws_methods::REVIEWS_FILES_VIEWED,
    ws_methods::REVIEWS_FILES_COMMENT,
    ws_methods::REVIEWS_FILES_LOCAL_CLONES_DELETE,
    ws_methods::REVIEWS_REVIEW_THREADS_RESOLVE,
];

const ADMIN_WS_METHODS: &[&str] = &[
    ws_methods::DAEMON_STOP,
    ws_methods::BRIDGE_RECONFIGURE,
    ws_methods::DAEMON_SET_LOG_LEVEL,
    ws_methods::TASK_BOARD_ORCHESTRATOR_GITHUB_TOKENS_SYNC,
    ws_methods::TASK_BOARD_ORCHESTRATOR_TODOIST_TOKEN_SYNC,
    ws_methods::TASK_BOARD_ORCHESTRATOR_OPENROUTER_TOKEN_SYNC,
    ws_methods::TASK_BOARD_ORCHESTRATOR_FORCE_CANCEL,
    ws_methods::TASK_BOARD_GIT_RUNTIME_KEY_MATERIAL_SYNC,
    ws_methods::TASK_BOARD_GIT_RUNTIME_SECRET_HANDOFF_PREPARE,
    ws_methods::TASK_BOARD_GIT_RUNTIME_SECRET_HANDOFF_ACK,
];
