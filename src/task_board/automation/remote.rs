use std::collections::BTreeSet;

use chrono::{DateTime, Duration, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};
use crate::task_board::remote_spki_pin;
use crate::task_board::{
    TaskBoardExecutionHostConfig, TaskBoardExecutionPhase, TaskBoardPhaseCapabilityProfile,
    normalize_repository_slug,
};

pub const TASK_BOARD_REMOTE_PROTOCOL_VERSION: u32 = 1;
pub const TASK_BOARD_REMOTE_HEARTBEAT_TTL_SECONDS: i64 = 300;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardRemoteAssignmentState {
    Offered,
    Claimed,
    Started,
    Running,
    Completed,
    Failed,
    Cancelled,
    Unknown,
    Superseded,
}

impl TaskBoardRemoteAssignmentState {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Offered => "offered",
            Self::Claimed => "claimed",
            Self::Started => "started",
            Self::Running => "running",
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
            Self::Unknown => "unknown",
            Self::Superseded => "superseded",
        }
    }

    /// Decode an exact durable assignment-state label.
    ///
    /// # Errors
    /// Returns [`CliError`] for unknown, noncanonical, or whitespace-padded labels.
    pub fn decode(value: &str) -> Result<Self, CliError> {
        match value {
            "offered" => Ok(Self::Offered),
            "claimed" => Ok(Self::Claimed),
            "started" => Ok(Self::Started),
            "running" => Ok(Self::Running),
            "completed" => Ok(Self::Completed),
            "failed" => Ok(Self::Failed),
            "cancelled" => Ok(Self::Cancelled),
            "unknown" => Ok(Self::Unknown),
            "superseded" => Ok(Self::Superseded),
            _ => Err(parse_error(format!(
                "invalid remote assignment state '{value}'"
            ))),
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardRemoteHostState {
    #[default]
    Healthy,
    Degraded,
    Unavailable,
    Disabled,
}

impl TaskBoardRemoteHostState {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Healthy => "healthy",
            Self::Degraded => "degraded",
            Self::Unavailable => "unavailable",
            Self::Disabled => "disabled",
        }
    }

    /// Decode an exact durable host-state label.
    ///
    /// # Errors
    /// Returns [`CliError`] for unknown, noncanonical, or whitespace-padded labels.
    pub fn decode(value: &str) -> Result<Self, CliError> {
        match value {
            "healthy" => Ok(Self::Healthy),
            "degraded" => Ok(Self::Degraded),
            "unavailable" => Ok(Self::Unavailable),
            "disabled" => Ok(Self::Disabled),
            _ => Err(parse_error(format!("invalid remote host state '{value}'"))),
        }
    }
}

pub type TaskBoardExecutionHostHealth = TaskBoardRemoteHostState;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TaskBoardExecutionCredentialReference {
    Environment { name: String },
    Keychain { service: String, account: String },
}

impl TaskBoardExecutionCredentialReference {
    /// Parse the credential resolvers implemented by the remote transport.
    ///
    /// Accepted references are exactly `env://NAME` and
    /// `keychain://service/account`. Values are strict ASCII identifiers; raw
    /// secrets and percent-encoded path material are rejected.
    ///
    /// # Errors
    /// Returns [`CliError`] for unsupported or noncanonical references.
    pub fn parse(reference: &str) -> Result<Self, CliError> {
        if let Some(name) = reference.strip_prefix("env://")
            && is_environment_name(name)
        {
            return Ok(Self::Environment {
                name: name.to_owned(),
            });
        }
        if let Some(path) = reference.strip_prefix("keychain://")
            && let Some((service, account)) = path.split_once('/')
            && !account.contains('/')
            && is_credential_segment(service)
            && is_credential_segment(account)
        {
            return Ok(Self::Keychain {
                service: service.to_owned(),
                account: account.to_owned(),
            });
        }
        Err(parse_error(
            "remote execution credentials must use env://NAME or keychain://service/account",
        ))
    }
}

/// Host state observed over the authenticated transport.
///
/// Endpoint, certificate pin, credential reference, and enablement are absent
/// deliberately: only operator settings own those trust decisions.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardExecutionHostAdvertisement {
    pub host_id: String,
    pub host_instance_id: String,
    pub protocol_version: u32,
    pub repositories: Vec<String>,
    pub runtimes: Vec<String>,
    pub capabilities: Vec<TaskBoardPhaseCapabilityProfile>,
    pub capacity: u32,
    pub active_assignments: u32,
    pub heartbeat_at: String,
}

impl TaskBoardExecutionHostAdvertisement {
    #[must_use]
    pub fn heartbeat_is_fresh_at(&self, now: DateTime<Utc>) -> bool {
        canonical_time(&self.heartbeat_at).is_ok_and(|heartbeat| {
            heartbeat <= now
                && heartbeat >= now - Duration::seconds(TASK_BOARD_REMOTE_HEARTBEAT_TTL_SECONDS)
        })
    }
}

/// Map only remotely executable worker phases to their required capability.
///
/// Planning, approval, publication, cleanup, and terminal transitions remain
/// controller-owned even when a similarly privileged capability exists.
///
/// # Errors
/// Returns [`CliError`] when the phase is not remotely executable.
pub fn remote_capability_for_phase(
    phase: TaskBoardExecutionPhase,
) -> Result<TaskBoardPhaseCapabilityProfile, CliError> {
    match phase {
        TaskBoardExecutionPhase::Implementation => {
            Ok(TaskBoardPhaseCapabilityProfile::ImplementationWrite)
        }
        TaskBoardExecutionPhase::Review => Ok(TaskBoardPhaseCapabilityProfile::ReviewReadOnly),
        TaskBoardExecutionPhase::Evaluate => Ok(TaskBoardPhaseCapabilityProfile::EvaluateReadOnly),
        TaskBoardExecutionPhase::Planning
        | TaskBoardExecutionPhase::AwaitingApproval
        | TaskBoardExecutionPhase::Publish
        | TaskBoardExecutionPhase::Cleanup
        | TaskBoardExecutionPhase::Terminal => Err(parse_error(format!(
            "task-board phase '{phase:?}' cannot execute remotely"
        ))),
    }
}

/// Validate one operator-owned remote host trust configuration.
///
/// # Errors
/// Returns [`CliError`] when identity, endpoint, pin, or credential reference
/// is unsafe or noncanonical.
pub fn validate_execution_host_config(host: &TaskBoardExecutionHostConfig) -> Result<(), CliError> {
    validate_canonical_id(&host.host_id, "remote execution host id")?;
    validate_https_origin(&host.endpoint)?;
    validate_certificate_fingerprint(&host.certificate_fingerprint)?;
    TaskBoardExecutionCredentialReference::parse(&host.credential_reference)?;
    Ok(())
}

/// Validate the complete operator-owned trust-anchor set.
///
/// # Errors
/// Returns [`CliError`] for an invalid host or duplicate identity/endpoint.
pub fn validate_execution_host_configs(
    hosts: &[TaskBoardExecutionHostConfig],
) -> Result<(), CliError> {
    let mut ids = BTreeSet::new();
    let mut endpoints = BTreeSet::new();
    for host in hosts {
        validate_execution_host_config(host)?;
        if !ids.insert(host.host_id.as_str()) {
            return Err(parse_error(format!(
                "duplicate remote execution host id '{}'",
                host.host_id
            )));
        }
        if !endpoints.insert(host.endpoint.as_str()) {
            return Err(parse_error(format!(
                "duplicate remote execution host endpoint '{}'",
                host.endpoint
            )));
        }
    }
    Ok(())
}

/// Validate observed host state without consulting or mutating trust anchors.
///
/// # Errors
/// Returns [`CliError`] when observed identity, protocol, repository/runtime
/// inventory, capability inventory, capacity, or heartbeat is noncanonical.
pub fn validate_execution_host_advertisement(
    host: &TaskBoardExecutionHostAdvertisement,
) -> Result<(), CliError> {
    validate_canonical_id(&host.host_id, "remote execution host id")?;
    validate_canonical_id(&host.host_instance_id, "remote execution host instance id")?;
    if host.protocol_version != TASK_BOARD_REMOTE_PROTOCOL_VERSION {
        return Err(CliErrorKind::workflow_version(format!(
            "remote execution host '{}' uses protocol {}, expected {}",
            host.host_id, host.protocol_version, TASK_BOARD_REMOTE_PROTOCOL_VERSION
        ))
        .into());
    }
    validate_repositories(&host.repositories)?;
    validate_runtime_inventory(&host.runtimes)?;
    validate_capability_inventory(&host.capabilities)?;
    if host.capacity == 0 || host.active_assignments > host.capacity {
        return Err(parse_error(format!(
            "remote execution host '{}' has invalid capacity {}/{}",
            host.host_id, host.active_assignments, host.capacity
        )));
    }
    canonical_time(&host.heartbeat_at)?;
    Ok(())
}

/// Validate that authenticated observed state belongs to one enabled trust entry.
///
/// # Errors
/// Returns [`CliError`] when either side is invalid, the configured host is
/// disabled, or the authenticated advertisement claims a different identity.
pub fn validate_execution_host_observation(
    configured: &TaskBoardExecutionHostConfig,
    observed: &TaskBoardExecutionHostAdvertisement,
) -> Result<(), CliError> {
    validate_execution_host_config(configured)?;
    validate_execution_host_advertisement(observed)?;
    if !configured.enabled {
        return Err(parse_error(format!(
            "remote execution host '{}' is disabled",
            configured.host_id
        )));
    }
    if configured.host_id != observed.host_id {
        return Err(parse_error(format!(
            "remote execution host identity mismatch: expected '{}', observed '{}'",
            configured.host_id, observed.host_id
        )));
    }
    Ok(())
}

fn validate_https_origin(endpoint: &str) -> Result<(), CliError> {
    let url = reqwest::Url::parse(endpoint)
        .map_err(|error| parse_error(format!("invalid remote execution host endpoint: {error}")))?;
    let canonical = url.origin().ascii_serialization();
    if url.scheme() == "https"
        && url.host_str().is_some()
        && url.username().is_empty()
        && url.password().is_none()
        && url.path() == "/"
        && url.query().is_none()
        && url.fragment().is_none()
        && endpoint == canonical
    {
        return Ok(());
    }
    Err(parse_error(
        "remote execution host endpoint must be a canonical HTTPS origin",
    ))
}

fn validate_certificate_fingerprint(fingerprint: &str) -> Result<(), CliError> {
    if remote_spki_pin::decode(fingerprint).is_some() {
        return Ok(());
    }
    Err(parse_error(
        "remote execution certificate fingerprint must be a canonical sha256/<base64> SPKI pin",
    ))
}

fn validate_repositories(repositories: &[String]) -> Result<(), CliError> {
    for repository in repositories {
        if normalize_repository_slug(Some(repository)).as_deref() != Some(repository) {
            return Err(parse_error(format!(
                "remote execution repository '{repository}' is not canonical"
            )));
        }
    }
    validate_strict_order(repositories, "remote execution repositories")
}

pub(super) fn validate_runtime_inventory(runtimes: &[String]) -> Result<(), CliError> {
    for runtime in runtimes {
        validate_canonical_id(runtime, "remote execution runtime")?;
    }
    validate_strict_order(runtimes, "remote execution runtimes")
}

pub(super) fn validate_capability_inventory(
    capabilities: &[TaskBoardPhaseCapabilityProfile],
) -> Result<(), CliError> {
    let mut previous = None;
    for capability in capabilities {
        let rank = match capability {
            TaskBoardPhaseCapabilityProfile::ImplementationWrite => 0,
            TaskBoardPhaseCapabilityProfile::ReviewReadOnly => 1,
            TaskBoardPhaseCapabilityProfile::EvaluateReadOnly => 2,
            TaskBoardPhaseCapabilityProfile::PlanningReadOnly => {
                return Err(parse_error(
                    "remote execution hosts cannot advertise controller-owned planning",
                ));
            }
        };
        if previous.is_some_and(|previous| previous >= rank) {
            return Err(parse_error(
                "remote execution capabilities must be sorted and unique",
            ));
        }
        previous = Some(rank);
    }
    Ok(())
}

fn validate_strict_order(values: &[String], label: &str) -> Result<(), CliError> {
    if values.windows(2).all(|pair| pair[0] < pair[1]) {
        Ok(())
    } else {
        Err(parse_error(format!("{label} must be sorted and unique")))
    }
}

pub(super) fn validate_canonical_id(value: &str, label: &str) -> Result<(), CliError> {
    let valid = (1..=128).contains(&value.len())
        && value.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'-' | b'_' | b'.')
        })
        && value
            .as_bytes()
            .first()
            .is_some_and(u8::is_ascii_alphanumeric)
        && value
            .as_bytes()
            .last()
            .is_some_and(u8::is_ascii_alphanumeric)
        && !value.contains("..");
    if valid {
        Ok(())
    } else {
        Err(parse_error(format!("{label} '{value}' is not canonical")))
    }
}

fn canonical_time(value: &str) -> Result<DateTime<Utc>, CliError> {
    let parsed = DateTime::parse_from_rfc3339(value)
        .map(DateTime::<Utc>::from)
        .map_err(|error| parse_error(format!("invalid remote host heartbeat: {error}")))?;
    if parsed.to_rfc3339_opts(SecondsFormat::AutoSi, true) == value {
        Ok(parsed)
    } else {
        Err(parse_error(
            "remote execution host heartbeat must be canonical UTC RFC 3339",
        ))
    }
}

fn is_environment_name(value: &str) -> bool {
    let mut bytes = value.bytes();
    bytes
        .next()
        .is_some_and(|byte| byte.is_ascii_alphabetic() || byte == b'_')
        && bytes.all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
}

fn is_credential_segment(value: &str) -> bool {
    (1..=128).contains(&value.len())
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
}

pub(super) fn parse_error(message: impl Into<String>) -> CliError {
    CliErrorKind::workflow_parse(message.into()).into()
}
